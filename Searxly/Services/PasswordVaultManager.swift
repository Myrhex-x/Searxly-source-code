//
//  PasswordVaultManager.swift
//  Searxly
//
//  On-device password vault coordinator: preferences, metadata, secrets, and browser fill helpers.
//  Secrets live in Keychain (PasswordVaultSecureStore); metadata in AppData.
//
//  Edition: the vault is exclusive to Searxly Maximum. The base app still compiles this code so both
//  targets share one codebase, but every surface (toolbar pill, Settings pane, utility tab, autofill /
//  save offer / generator hooks) gates on `isAvailable` — which is a compile-time false in the base
//  app, so those branches are dead there.
//

import Foundation
import os
import LocalAuthentication
import Security

@MainActor
@Observable
final class PasswordVaultManager {
    static let shared = PasswordVaultManager()

    /// Available in BOTH editions (2026-07-19: the vault was brought back to the base app). Kept as a
    /// single flag — rather than `true` inline everywhere — so the product rule stays in one place and
    /// is trivial to re-gate later. Every vault entry point (Settings, toolbar, import, autofill) reads
    /// this, so flipping it here surfaces or hides the whole feature.
    nonisolated static var isAvailable: Bool { true }

    private(set) var savedLoginCount: Int = 0
    private(set) var entries: [PasswordVaultEntry] = []
    private(set) var isVaultUnlocked: Bool = false

    var useCustomVaultPassphrase: Bool {
        VaultLockManager.shared.useCustomPassphrase
    }

    /// Effective autofill — always off when the vault isn't in this edition.
    var autofillEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    /// Effective offer-to-save — always off when the vault isn't in this edition.
    var offerToSaveEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    /// Effective generator — always off when the vault isn't in this edition.
    var suggestPasswordsEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    var copyGeneratedToClipboard: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    /// Convenience used by browser hooks so a single check covers edition + preference.
    var isAutofillActive: Bool { Self.isAvailable && autofillEnabled }
    var isOfferToSaveActive: Bool { Self.isAvailable && offerToSaveEnabled }
    var isSuggestPasswordsActive: Bool { Self.isAvailable && suggestPasswordsEnabled }

    var autoLockMinutes: Int = 10 {
        didSet {
            guard !isLoadingPreferences else { return }
            let clamped = max(0, min(autoLockMinutes, 1440))
            if clamped != autoLockMinutes {
                autoLockMinutes = clamped
                return
            }
            PasswordVaultStore.saveAutoLockMinutes(clamped)
            restartAutoLockTimer()
        }
    }

    private var isLoadingPreferences = false
    private var lastVaultActivity = Date()
    private var autoLockTimer: Timer?
    private var authInProgress = false

    private init() {
        reloadFromPersistence()
    }

    // MARK: - Persistence

    func reloadFromPersistence() {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }

        VaultLockManager.shared.reloadFromPersistence()

        entries = PasswordVaultStore.loadEntries()
            .sorted { lhs, rhs in
                if lhs.domain != rhs.domain { return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending }
                return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
        savedLoginCount = entries.count

        let behavior = PasswordVaultStore.loadBehaviorPreferences()
        autofillEnabled = behavior.autofillEnabled
        offerToSaveEnabled = behavior.offerToSaveEnabled
        suggestPasswordsEnabled = behavior.suggestPasswordsEnabled
        copyGeneratedToClipboard = behavior.copyGeneratedToClipboard
        autoLockMinutes = PasswordVaultStore.loadAutoLockMinutes()
    }

    private func persistEntries() {
        PasswordVaultStore.saveEntries(entries)
        savedLoginCount = entries.count
    }

    private func persistBehaviorPreferences() {
        guard !isLoadingPreferences else { return }
        PasswordVaultStore.saveBehaviorPreferences(
            autofillEnabled: autofillEnabled,
            offerToSaveEnabled: offerToSaveEnabled,
            suggestPasswordsEnabled: suggestPasswordsEnabled,
            copyGeneratedToClipboard: copyGeneratedToClipboard
        )
    }

    // MARK: - Vault lock

    func unlockVault(passphrase: String? = nil) async -> Bool {
        guard Self.isAvailable else { return false }
        guard !authInProgress else { return false }
        authInProgress = true
        defer { authInProgress = false }

        let success: Bool
        if VaultLockManager.shared.useCustomPassphrase {
            guard let passphrase, VaultLockManager.shared.verifyPassphrase(passphrase) else {
                return false
            }
            success = true
        } else {
            success = await authenticate(reason: "Unlock your password vault")
        }

        if success {
            // Second factor: when a security key is required for the vault, biometric / passphrase
            // success alone isn't enough — also require a tap on an enrolled key before opening.
            guard await SecurityKeyManager.shared.assertIfRequiredForVault() else {
                return false
            }
            isVaultUnlocked = true
            recordVaultActivity()
            restartAutoLockTimer()
            reconcileTOTPFlags()
        }
        return success
    }

    func lockVault() {
        isVaultUnlocked = false
        stopAutoLockTimer()
        VaultClipboardManager.shared.clearIfStillOurs()
    }

    func recordVaultActivity() {
        lastVaultActivity = Date()
    }

    private var activeVaultAuthContext: LAContext?

    private func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            activeVaultAuthContext = context
            context.localizedCancelTitle = "Cancel"
            context.localizedFallbackTitle = "Use Password"

            var evalError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
                activeVaultAuthContext = nil
                Log.security.error("Passwords: biometric auth unavailable: \(evalError?.localizedDescription ?? "unknown", privacy: .public)")
                continuation.resume(returning: false)
                return
            }

            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
                Task { @MainActor [weak self] in
                    self?.activeVaultAuthContext = nil
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func restartAutoLockTimer() {
        stopAutoLockTimer()
        guard isVaultUnlocked, autoLockMinutes > 0 else { return }

        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAutoLock()
            }
        }
    }

    private func stopAutoLockTimer() {
        autoLockTimer?.invalidate()
        autoLockTimer = nil
    }

    private func checkAutoLock() {
        guard isVaultUnlocked, autoLockMinutes > 0 else { return }
        let elapsed = Date().timeIntervalSince(lastVaultActivity)
        if elapsed >= TimeInterval(autoLockMinutes * 60) {
            lockVault()
        }
    }

    // MARK: - CRUD

    static func normalizeDomain(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            if let host = URL(string: value)?.host {
                value = host
            }
        }
        // Strip anything after the host if a "host/path" or "host:port" slipped in — otherwise a
        // malformed stored domain would widen (or break) autofill matching.
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    func entries(matching query: String) -> [PasswordVaultEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.domain.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
                || ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    func entries(forDomain domain: String) -> [PasswordVaultEntry] {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return [] }
        return entries.filter { entry in
            let stored = entry.domain
            guard !stored.isEmpty else { return false }
            // Exact host match…
            if stored == normalized { return true }
            // …or the stored domain is a registrable parent of the current host (saved "github.com"
            // matches "login.github.com"). Gated on the stored value containing a dot so a malformed or
            // over-broad entry like "com" can never be offered for every site under that TLD.
            guard stored.contains(".") else { return false }
            return normalized.hasSuffix(".\(stored)")
        }
    }

    @discardableResult
    func addEntry(domain: String, username: String, password: String, notes: String? = nil) -> PasswordVaultEntry? {
        guard Self.isAvailable else { return nil }
        let normalizedDomain = Self.normalizeDomain(domain)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // NEVER trim the password: a leading/trailing space can be part of a real password, and
        // silently stripping it would save a password that no longer works. Only reject an empty one.
        guard !normalizedDomain.isEmpty, !trimmedUsername.isEmpty, !password.isEmpty else { return nil }

        // De-dupe: re-saving the same site + username updates the existing login (and its stored
        // password) instead of creating a second entry that would leave an orphan Keychain item and
        // split one account across two rows. Matches the CSV importer's dedupe behavior.
        if let existing = entries.first(where: { $0.domain == normalizedDomain && $0.username == trimmedUsername }) {
            guard updateEntry(id: existing.id, domain: normalizedDomain, username: trimmedUsername,
                              password: password, notes: notes) else { return nil }
            return entries.first { $0.id == existing.id }
        }

        let entry = PasswordVaultEntry(
            domain: normalizedDomain,
            username: trimmedUsername,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )

        guard PasswordVaultSecureStore.savePassword(password, for: entry.id) else { return nil }

        entries.append(entry)
        entries.sort { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending }
            return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
        }
        persistEntries()
        recordVaultActivity()
        return entry
    }

    @discardableResult
    func updateEntry(
        id: UUID,
        domain: String,
        username: String,
        password: String?,
        notes: String?
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }

        let normalizedDomain = Self.normalizeDomain(domain)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDomain.isEmpty, !trimmedUsername.isEmpty else { return false }

        // Password stored verbatim (never trimmed — see addEntry). A nil/empty password means
        // "keep the existing one" (the editor pre-fills it, so a blank field is a no-op, not a wipe).
        if let password, !password.isEmpty {
            guard PasswordVaultSecureStore.savePassword(password, for: id) else { return false }
        }

        entries[index].domain = normalizedDomain
        entries[index].username = trimmedUsername
        entries[index].notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        entries.sort { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending }
            return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
        }
        persistEntries()
        recordVaultActivity()
        return true
    }

    func deleteEntry(id: UUID) {
        // Removes the password AND any TOTP seed — an orphaned seed would be unreachable but
        // still sensitive material left sitting in the Keychain.
        PasswordVaultSecureStore.deleteSecrets(for: id)
        entries.removeAll { $0.id == id }
        persistEntries()
        recordVaultActivity()
    }

    func password(for entryID: UUID) -> String? {
        guard isVaultUnlocked else { return nil }
        recordVaultActivity()
        return PasswordVaultSecureStore.loadPassword(for: entryID)
    }

    func markEntryUsed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastUsed = Date()
        persistEntries()
    }

    func clearAllVaultData() {
        PasswordVaultSecureStore.deleteAllSecrets()
        entries = []
        persistEntries()
        lockVault()
        Log.security.notice("Passwords: cleared vault metadata and Keychain secrets")
    }

    // MARK: - TOTP (two-factor codes)

    /// Attaches a TOTP seed to an existing login. `raw` is whatever the user pasted — a full
    /// `otpauth://` URI from a QR code, or the bare Base32 secret sites print beside it.
    /// Returns false when the input doesn't parse, so the UI can say so instead of storing junk
    /// that would silently generate codes no site accepts.
    @discardableResult
    func setTOTP(from raw: String, for entryID: UUID) -> Bool {
        guard Self.isAvailable,
              let index = entries.firstIndex(where: { $0.id == entryID }),
              var configuration = TOTPGenerator.parse(raw) else { return false }

        // Label the seed with the login it belongs to, so a future export carries meaningful
        // issuer/account values even when the pasted URI had none.
        if configuration.issuer == nil { configuration.issuer = entries[index].domain }
        if configuration.account == nil { configuration.account = entries[index].username }

        guard PasswordVaultSecureStore.saveTOTPURI(TOTPGenerator.uri(for: configuration), for: entryID) else {
            return false
        }

        entries[index].hasTOTP = true
        persistEntries()
        recordVaultActivity()
        return true
    }

    func removeTOTP(for entryID: UUID) {
        PasswordVaultSecureStore.deleteTOTPURI(for: entryID)
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].hasTOTP = false
            persistEntries()
        }
        recordVaultActivity()
    }

    /// The stored TOTP configuration. Unlock-gated for the same reason `password(for:)` is: the
    /// Keychain items are `WhenUnlockedThisDeviceOnly`, so they stay readable whenever the Mac is
    /// unlocked regardless of the VAULT lock — without this guard the vault lock would be
    /// bypassable for second-factor seeds.
    func totpConfiguration(for entryID: UUID) -> TOTPConfiguration? {
        guard isVaultUnlocked,
              let uri = PasswordVaultSecureStore.loadTOTPURI(for: entryID) else { return nil }
        return TOTPGenerator.parse(uri)
    }

    /// The code showing right now, or nil when locked / no seed stored.
    func currentTOTPCode(for entryID: UUID) -> String? {
        guard let configuration = totpConfiguration(for: entryID) else { return nil }
        return TOTPGenerator.code(for: configuration)
    }

    func copyTOTPToClipboard(for entryID: UUID) -> Bool {
        guard let code = currentTOTPCode(for: entryID) else { return false }
        VaultClipboardManager.shared.copySensitive(code)
        recordVaultActivity()
        return true
    }

    /// Reconciles the `hasTOTP` flags against what is actually in the Keychain. The flag lives in
    /// the metadata file while the seed lives in the Keychain, so the two can drift — a restored
    /// backup of PasswordVault.json, or a Keychain wiped independently of the app, both leave a
    /// flag pointing at nothing. Cheap enough to run on unlock; requires the vault to be unlocked
    /// because it reads the secure store.
    func reconcileTOTPFlags() {
        guard isVaultUnlocked else { return }
        var changed = false
        for index in entries.indices {
            let present = PasswordVaultSecureStore.loadTOTPURI(for: entries[index].id) != nil
            if entries[index].hasTOTP != present {
                entries[index].hasTOTP = present
                changed = true
            }
        }
        if changed {
            persistEntries()
            Log.security.notice("Passwords: reconciled TOTP presence flags against the Keychain")
        }
    }

    func suggestPasswordWithAI(for domain: String) async -> String {
        _ = domain
        return Self.generateSecurePassword(length: 20)
    }

    static func generateSecurePassword(length: Int = 20) -> String {
        let lower   = Array("abcdefghijklmnopqrstuvwxyz")
        let upper   = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits  = Array("0123456789")
        let symbols = Array("!@#$%^&*")
        let all = lower + upper + digits + symbols
        guard length > 0 else { return "" }

        /// One uniformly-random member of `set`, rejection-sampled so no character is biased
        /// (256 % 70 ≠ 0 → naïve modulo would over-represent the low indices).
        func pick(_ set: [Character]) -> Character {
            let ceiling = UInt8((256 / set.count) * set.count)
            while true {
                var byte: UInt8 = 0
                guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { continue }
                if byte < ceiling { return set[Int(byte) % set.count] }
            }
        }

        var chars: [Character] = []
        // Guarantee at least one of each class (up to what length allows) so the result satisfies
        // sites that require mixed classes and never lands in a "weak" bucket by chance.
        for set in [lower, upper, digits, symbols].prefix(max(1, length)) {
            chars.append(pick(set))
        }
        while chars.count < length { chars.append(pick(all)) }

        // Fisher–Yates so the guaranteed class characters aren't pinned to the first four positions.
        // SystemRandomNumberGenerator is arc4random-backed (CSPRNG) on Apple platforms.
        var rng = SystemRandomNumberGenerator()
        chars.shuffle(using: &rng)
        return String(chars)
    }

    func copyPasswordToClipboard(for entryID: UUID) -> Bool {
        guard let password = password(for: entryID) else { return false }
        VaultClipboardManager.shared.copySensitive(password)
        markEntryUsed(id: entryID)
        return true
    }

    func copyGeneratedPasswordToClipboard(_ password: String) {
        VaultClipboardManager.shared.copySensitive(password)
    }

    // MARK: - Export

    enum ExportError: Error { case locked, empty }

    /// Builds a plaintext CSV of every saved login, using the Chrome/Safari column order
    /// (`name,url,username,password,note`) so it re-imports into any browser or password manager —
    /// including Searxly's own importer. Requires the vault to be UNLOCKED (reads each secret from the
    /// Keychain); refuses otherwise so the lock can't be bypassed. The caller writes it to a
    /// user-chosen file and is responsible for warning that the file is UNENCRYPTED plaintext.
    ///
    /// Two-factor seeds are EXCLUDED unless `includeTOTP` is explicitly set. A TOTP seed in a
    /// plaintext file hands over the second factor permanently — and worse, it does so silently,
    /// alongside a password the user already knew was in there. Exporting it has to be a separate,
    /// deliberate choice, not a side effect of backing up passwords.
    func exportCSV(includeTOTP: Bool = false) throws -> String {
        guard isVaultUnlocked else { throw ExportError.locked }
        recordVaultActivity()

        func esc(_ field: String) -> String {
            // RFC-4180: quote fields containing comma, quote, or newline; double interior quotes.
            if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }

        // `totp` is the column name Bitwarden and 1Password both read back, so an export with
        // seeds included round-trips into them as well as into Searxly's own importer.
        var rows: [String] = [includeTOTP ? "name,url,username,password,note,totp" : "name,url,username,password,note"]
        for entry in entries {
            guard let password = PasswordVaultSecureStore.loadPassword(for: entry.id) else { continue }
            let url = entry.domain.isEmpty ? "" : "https://\(entry.domain)"
            var cols = [entry.domain, url, entry.username, password, entry.notes ?? ""]
            if includeTOTP {
                cols.append(entry.hasTOTP ? (PasswordVaultSecureStore.loadTOTPURI(for: entry.id) ?? "") : "")
            }
            rows.append(cols.map(esc).joined(separator: ","))
        }
        guard rows.count > 1 else { throw ExportError.empty }
        return rows.joined(separator: "\n") + "\n"
    }
}

@MainActor
@Observable
final class VaultLockManager {
    static let shared = VaultLockManager()

    private(set) var useCustomPassphrase: Bool = false

    private let minimumPassphraseLength = 8

    private init() {
        reloadFromPersistence()
    }

    func reloadFromPersistence() {
        let config = PasswordVaultStore.loadLockConfig()
        useCustomPassphrase = config.useCustom
            && config.salt != nil
            && config.verifier != nil
    }

    @discardableResult
    func setCustomPassphrase(_ passphrase: String) -> Bool {
        guard passphrase.count >= minimumPassphraseLength,
              let salt = VaultPassphraseCrypto.generateSalt(),
              let verifier = VaultPassphraseCrypto.deriveVerifier(passphrase: passphrase, salt: salt) else {
            return false
        }

        PasswordVaultStore.saveLockConfig(useCustom: true, salt: salt, verifier: verifier,
                                          iterations: VaultPassphraseCrypto.currentIterations)
        useCustomPassphrase = true
        PasswordVaultManager.shared.lockVault()
        return true
    }

    func verifyPassphrase(_ passphrase: String) -> Bool {
        let config = PasswordVaultStore.loadLockConfig()
        guard let salt = config.salt, let verifier = config.verifier else { return false }
        guard VaultPassphraseCrypto.verify(passphrase: passphrase, salt: salt, verifier: verifier,
                                           iterations: config.iterations) else { return false }

        // Correct passphrase, but the stored verifier is at an old work factor. This is the only
        // moment we hold the plaintext passphrase, so re-derive at the current count and persist —
        // same transparent-upgrade pattern the wallet uses for its legacy seed KDF. A failure to
        // re-derive leaves the old verifier in place, which still unlocks; never fail the unlock.
        if config.iterations < VaultPassphraseCrypto.currentIterations {
            if let upgraded = VaultPassphraseCrypto.deriveVerifier(passphrase: passphrase, salt: salt) {
                PasswordVaultStore.saveLockConfig(useCustom: true, salt: salt, verifier: upgraded,
                                                  iterations: VaultPassphraseCrypto.currentIterations)
            }
        }
        return true
    }

    @discardableResult
    func changePassphrase(from current: String, to newPassphrase: String) -> Bool {
        guard verifyPassphrase(current), newPassphrase.count >= minimumPassphraseLength else { return false }
        return setCustomPassphrase(newPassphrase)
    }

    @discardableResult
    func removeCustomPassphrase(verifying passphrase: String) -> Bool {
        guard verifyPassphrase(passphrase) else { return false }
        clearAllVaultLockData()
        return true
    }

    func clearAllVaultLockData() {
        PasswordVaultStore.saveLockConfig(useCustom: false, salt: nil, verifier: nil,
                                          iterations: VaultPassphraseCrypto.currentIterations)
        useCustomPassphrase = false
        PasswordVaultManager.shared.lockVault()
        Log.security.notice("Passwords: cleared vault lock configuration")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}