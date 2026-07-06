//
//  PasswordVaultManager.swift
//  Searxly
//
//  On-device password vault coordinator: preferences, metadata, secrets, and browser fill helpers.
//  Secrets live in Keychain (PasswordVaultSecureStore); metadata in AppData.
//

import Foundation
import os
import LocalAuthentication
import Security

@MainActor
@Observable
final class PasswordVaultManager {
    static let shared = PasswordVaultManager()

    private(set) var savedLoginCount: Int = 0
    private(set) var entries: [PasswordVaultEntry] = []
    private(set) var isVaultUnlocked: Bool = false

    var useCustomVaultPassphrase: Bool {
        VaultLockManager.shared.useCustomPassphrase
    }

    var autofillEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    var offerToSaveEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    var suggestPasswordsEnabled: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

    var copyGeneratedToClipboard: Bool = true {
        didSet { persistBehaviorPreferences() }
    }

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
        PasswordVaultSecureStore.deletePassword(for: id)
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
        PasswordVaultSecureStore.deleteAllPasswords()
        entries = []
        persistEntries()
        lockVault()
        Log.security.notice("Passwords: cleared vault metadata and Keychain secrets")
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
    func exportCSV() throws -> String {
        guard isVaultUnlocked else { throw ExportError.locked }
        recordVaultActivity()

        func esc(_ field: String) -> String {
            // RFC-4180: quote fields containing comma, quote, or newline; double interior quotes.
            if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }

        var rows: [String] = ["name,url,username,password,note"]
        for entry in entries {
            guard let password = PasswordVaultSecureStore.loadPassword(for: entry.id) else { continue }
            let url = entry.domain.isEmpty ? "" : "https://\(entry.domain)"
            let cols = [entry.domain, url, entry.username, password, entry.notes ?? ""].map(esc)
            rows.append(cols.joined(separator: ","))
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

        PasswordVaultStore.saveLockConfig(useCustom: true, salt: salt, verifier: verifier)
        useCustomPassphrase = true
        PasswordVaultManager.shared.lockVault()
        return true
    }

    func verifyPassphrase(_ passphrase: String) -> Bool {
        let config = PasswordVaultStore.loadLockConfig()
        guard let salt = config.salt, let verifier = config.verifier else { return false }
        return VaultPassphraseCrypto.verify(passphrase: passphrase, salt: salt, verifier: verifier)
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
        PasswordVaultStore.saveLockConfig(useCustom: false, salt: nil, verifier: nil)
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