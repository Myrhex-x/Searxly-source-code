//
//  PasswordVaultStore.swift
//  Searxly
//
//  Dedicated, resilient on-disk store for password-vault METADATA — the index of saved logins
//  plus the vault's lock configuration and behavior preferences.
//
//  Why this is separate from AppData.json:
//  Each login's secret lives in the Keychain (PasswordVaultSecureStore). The *index* that records
//  which logins exist (domain, username, notes, the entry UUIDs) used to live inside the shared
//  AppData.json — the same file that holds history, bookmarks, tabs, VPN, AI prefs, etc. A decode
//  failure of any unrelated field in that large shared file resets the WHOLE file to defaults,
//  which wiped the vault index and left the Keychain secrets orphaned (present but unreachable).
//
//  Isolating the vault into its own small file — with fully tolerant decoding so a single bad or
//  schema-changed field degrades to a default instead of discarding everything — means nothing
//  outside the vault can ever erase a saved login. Combined with the device-only, non-synced
//  Keychain secrets, a saved login now persists until the user deletes it, deletes the app, or
//  loses the machine. File lives next to AppData.json and carries the same at-rest protection.
//

import Foundation
import os

/// The full persisted state of the password vault (everything except the secrets themselves,
/// which live in the Keychain via `PasswordVaultSecureStore`).
struct PasswordVaultData: Codable {
    var entries: [PasswordVaultEntry] = []

    // Optional vault-only custom passphrase: PBKDF2 salt + verifier hash, never the passphrase.
    var useCustomPassword: Bool = false
    var customSalt: Data?
    var customVerifier: Data?

    // Auto-lock + behavior preferences.
    var autoLockMinutes: Int = 10
    var autofillEnabled: Bool = true
    var offerToSaveEnabled: Bool = true
    var suggestPasswordsEnabled: Bool = true
    var copyGeneratedToClipboard: Bool = true

    init() {}

    /// Fully tolerant decode. Every field is optional-with-default, and each is individually
    /// wrapped so a single bad/changed field can never throw away the entire vault. The entries
    /// array is decoded element-by-element so one malformed login cannot discard the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if var unkeyed = try? c.nestedUnkeyedContainer(forKey: .entries) {
            var collected: [PasswordVaultEntry] = []
            if let count = unkeyed.count { collected.reserveCapacity(count) }
            while !unkeyed.isAtEnd {
                if let entry = try? unkeyed.decode(PasswordVaultEntry.self) {
                    collected.append(entry)
                } else {
                    // A throwing decode does not advance the unkeyed container; consume the bad
                    // element with a no-op type so we move on instead of looping forever.
                    _ = try? unkeyed.decode(SkipOne.self)
                }
            }
            entries = collected
        } else {
            entries = []
        }

        useCustomPassword        = (try? c.decodeIfPresent(Bool.self, forKey: .useCustomPassword)) ?? false
        customSalt               = (try? c.decodeIfPresent(Data.self, forKey: .customSalt)) ?? nil
        customVerifier           = (try? c.decodeIfPresent(Data.self, forKey: .customVerifier)) ?? nil
        autoLockMinutes          = (try? c.decodeIfPresent(Int.self, forKey: .autoLockMinutes)) ?? 10
        autofillEnabled          = (try? c.decodeIfPresent(Bool.self, forKey: .autofillEnabled)) ?? true
        offerToSaveEnabled       = (try? c.decodeIfPresent(Bool.self, forKey: .offerToSaveEnabled)) ?? true
        suggestPasswordsEnabled  = (try? c.decodeIfPresent(Bool.self, forKey: .suggestPasswordsEnabled)) ?? true
        copyGeneratedToClipboard = (try? c.decodeIfPresent(Bool.self, forKey: .copyGeneratedToClipboard)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case useCustomPassword
        case customSalt
        case customVerifier
        case autoLockMinutes
        case autofillEnabled
        case offerToSaveEnabled
        case suggestPasswordsEnabled
        case copyGeneratedToClipboard
    }

    /// No-op element used to advance the unkeyed entries container past a malformed login.
    private struct SkipOne: Decodable { init(from decoder: Decoder) throws {} }
}

/// Reads and writes the password-vault metadata file. Mirrors the small surface the vault managers
/// need; all writes are atomic and file-protected, all reads are non-destructive.
enum PasswordVaultStore {
    private static let fileName = "PasswordVault.json"

    private static var fileURL: URL {
        Persistence.appDataFileURL().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    // MARK: - Whole-record load / save

    /// Loads the vault metadata. On first run (no dedicated file yet) it migrates the vault fields
    /// out of the legacy AppData.json and establishes the dedicated file. Never overwrites readable
    /// data: if the dedicated file is unreadable it is quarantined rather than reset.
    static func load() -> PasswordVaultData {
        let url = fileURL

        if FileManager.default.fileExists(atPath: url.path) {
            if let raw = try? Data(contentsOf: url),
               let decoded = try? makeDecoder().decode(PasswordVaultData.self, from: raw) {
                return decoded
            }
            // Present but unreadable despite tolerant decoding (truncation / garbage bytes):
            // preserve the bytes instead of silently wiping the user's logins.
            quarantine(url)
        }

        // No usable dedicated file yet → one-time migration from the legacy shared AppData.json.
        let migrated = migrateFromLegacyAppData()
        save(migrated)
        return migrated
    }

    static func save(_ data: PasswordVaultData) {
        do {
            let json = try makeEncoder().encode(data)
            try json.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            Log.security.error("PasswordVaultStore: failed to save vault metadata — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Granular accessors (used by PasswordVaultManager / VaultLockManager)

    static func loadEntries() -> [PasswordVaultEntry] { load().entries }

    static func saveEntries(_ entries: [PasswordVaultEntry]) {
        var data = load()
        data.entries = entries
        save(data)
    }

    static func loadLockConfig() -> (useCustom: Bool, salt: Data?, verifier: Data?) {
        let d = load()
        return (d.useCustomPassword, d.customSalt, d.customVerifier)
    }

    static func saveLockConfig(useCustom: Bool, salt: Data?, verifier: Data?) {
        var data = load()
        data.useCustomPassword = useCustom
        data.customSalt = salt
        data.customVerifier = verifier
        save(data)
    }

    static func loadAutoLockMinutes() -> Int { load().autoLockMinutes }

    static func saveAutoLockMinutes(_ minutes: Int) {
        var data = load()
        data.autoLockMinutes = max(0, min(minutes, 1440)) // cap at 24h
        save(data)
    }

    static func loadBehaviorPreferences() -> (
        autofillEnabled: Bool,
        offerToSaveEnabled: Bool,
        suggestPasswordsEnabled: Bool,
        copyGeneratedToClipboard: Bool
    ) {
        let d = load()
        return (d.autofillEnabled, d.offerToSaveEnabled, d.suggestPasswordsEnabled, d.copyGeneratedToClipboard)
    }

    static func saveBehaviorPreferences(
        autofillEnabled: Bool,
        offerToSaveEnabled: Bool,
        suggestPasswordsEnabled: Bool,
        copyGeneratedToClipboard: Bool
    ) {
        var data = load()
        data.autofillEnabled = autofillEnabled
        data.offerToSaveEnabled = offerToSaveEnabled
        data.suggestPasswordsEnabled = suggestPasswordsEnabled
        data.copyGeneratedToClipboard = copyGeneratedToClipboard
        save(data)
    }

    // MARK: - Helpers

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One-time migration: pull the vault fields out of the legacy shared AppData.json. Reads the
    /// raw AppData struct directly (not a convenience method) so there is no risk of recursion.
    private static func migrateFromLegacyAppData() -> PasswordVaultData {
        let legacy = Persistence.load()
        var data = PasswordVaultData()
        data.entries = legacy.passwordVaultEntries
        data.useCustomPassword = legacy.passwordVaultUseCustomPassword
        data.customSalt = legacy.passwordVaultCustomSalt
        data.customVerifier = legacy.passwordVaultCustomVerifier
        data.autoLockMinutes = legacy.passwordVaultAutoLockMinutes
        data.autofillEnabled = legacy.passwordVaultAutofillEnabled
        data.offerToSaveEnabled = legacy.passwordVaultOfferToSaveEnabled
        data.suggestPasswordsEnabled = legacy.passwordVaultSuggestPasswordsEnabled
        data.copyGeneratedToClipboard = legacy.passwordVaultCopyGeneratedToClipboard

        if !data.entries.isEmpty || data.useCustomPassword {
            Log.security.notice("PasswordVaultStore: migrated \(data.entries.count) vault entr(ies) from legacy AppData.json into the dedicated store")
        }
        return data
    }

    private static func quarantine(_ url: URL) {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(fileName).broken-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            Log.security.error("PasswordVaultStore: vault metadata unreadable; quarantined to \(dest.lastPathComponent, privacy: .public) (not deleted)")
        } catch {
            Log.security.error("PasswordVaultStore: could not quarantine unreadable vault metadata: \(error.localizedDescription, privacy: .public)")
        }
    }
}
