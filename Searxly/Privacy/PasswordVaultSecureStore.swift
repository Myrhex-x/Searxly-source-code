//
//  PasswordVaultSecureStore.swift
//  Searxly
//
//  Keychain storage for password vault secrets. One generic-password item per entry ID.
//  Uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly (device-only, not iCloud-synced).
//  Vault unlock (Touch ID / passphrase) is the user-facing gate; per-item userPresence
//  SecAccessControl requires entitlements this app does not declare on macOS.
//
//  TWO secret kinds live here, in separate Keychain services keyed by the same entry UUID:
//  the login password, and the TOTP `otpauth://` URI (a second-factor seed, which is exactly as
//  sensitive as the password — anyone holding it can mint valid codes indefinitely). Keeping
//  them in distinct services means a password read can never accidentally return a TOTP seed,
//  and each can be wiped independently.
//

import Foundation
import os
import Security

nonisolated enum PasswordVaultSecureStore: Sendable {
    private static let passwordService = "com.searxly.password-vault"
    private static let totpService = "com.searxly.password-vault.totp"

    // Use the data-protection keychain (no signature-ACL prompts) when available; otherwise legacy.
    private static var dp: Bool { KeychainDataProtection.isAvailable }

    private static func baseQuery(service: String, entryID: UUID, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryID.uuidString,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: - Passwords

    @discardableResult
    static func savePassword(_ password: String, for entryID: UUID) -> Bool {
        save(password, service: passwordService, entryID: entryID)
    }

    static func loadPassword(for entryID: UUID) -> String? {
        load(service: passwordService, entryID: entryID)
    }

    @discardableResult
    static func deletePassword(for entryID: UUID) -> Bool {
        delete(service: passwordService, entryID: entryID)
    }

    /// Removes every password item for this vault service (both keychains).
    static func deleteAllPasswords() {
        wipeService(passwordService)
    }

    // MARK: - TOTP seeds

    /// Stores the canonical `otpauth://` URI for an entry. Callers must have already validated it
    /// parses — this layer only moves bytes.
    @discardableResult
    static func saveTOTPURI(_ uri: String, for entryID: UUID) -> Bool {
        save(uri, service: totpService, entryID: entryID)
    }

    static func loadTOTPURI(for entryID: UUID) -> String? {
        load(service: totpService, entryID: entryID)
    }

    @discardableResult
    static func deleteTOTPURI(for entryID: UUID) -> Bool {
        delete(service: totpService, entryID: entryID)
    }

    // MARK: - Combined

    /// Deletes every secret belonging to one entry. Used when a login is removed so a TOTP seed
    /// can never outlive the entry that referenced it (an orphan seed is unreachable but still
    /// sensitive material sitting in the Keychain).
    static func deleteSecrets(for entryID: UUID) {
        deletePassword(for: entryID)
        deleteTOTPURI(for: entryID)
    }

    /// Removes every vault secret of every kind. Backs "Clear all vault data".
    static func deleteAllSecrets() {
        wipeService(passwordService)
        wipeService(totpService)
    }

    // MARK: - Shared implementation

    private static func save(_ value: String, service: String, entryID: UUID) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Standard Keychain upsert: try update first to eliminate the delete→add window where
        // a crash between the two calls would silently lose the secret.
        let match = baseQuery(service: service, entryID: entryID, dataProtection: dp)
        let updateStatus = SecItemUpdate(match as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)

        if updateStatus == errSecSuccess { return true }

        // Item doesn't exist yet (errSecItemNotFound) — add it.
        // Any other update error is unexpected; surface it and abort.
        guard updateStatus == errSecItemNotFound else {
            #if DEBUG
            Log.security.error("[PasswordVaultSecureStore] update failed status=\(updateStatus) entry=\(entryID)")
            #endif
            return false
        }

        var addQuery = baseQuery(service: service, entryID: entryID, dataProtection: dp)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        #if DEBUG
        if addStatus != errSecSuccess {
            Log.security.error("[PasswordVaultSecureStore] add failed status=\(addStatus) entry=\(entryID)")
        }
        #endif

        if addStatus == errSecSuccess {
            // Drop any legacy copy so it never prompts again.
            if dp { SecItemDelete(baseQuery(service: service, entryID: entryID, dataProtection: false) as CFDictionary) }
            return true
        }
        return false
    }

    private static func load(service: String, entryID: UUID) -> String? {
        if dp {
            if let value = rawLoad(service: service, entryID: entryID, dataProtection: true) { return value }
            // Migrate a legacy-keychain entry into the data-protection keychain (one-time).
            if let legacy = rawLoad(service: service, entryID: entryID, dataProtection: false) {
                migrate(legacy, service: service, entryID: entryID)
                return legacy
            }
            return nil
        }
        return rawLoad(service: service, entryID: entryID, dataProtection: false)
    }

    private static func rawLoad(service: String, entryID: UUID, dataProtection: Bool) -> String? {
        var query = baseQuery(service: service, entryID: entryID, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func migrate(_ value: String, service: String, entryID: UUID) {
        guard let data = value.data(using: .utf8) else { return }
        var add = baseQuery(service: service, entryID: entryID, dataProtection: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            SecItemDelete(baseQuery(service: service, entryID: entryID, dataProtection: false) as CFDictionary)
        }
    }

    private static func delete(service: String, entryID: UUID) -> Bool {
        var ok = true
        if dp {
            let s = SecItemDelete(baseQuery(service: service, entryID: entryID, dataProtection: true) as CFDictionary)
            ok = (s == errSecSuccess || s == errSecItemNotFound)
        }
        let s2 = SecItemDelete(baseQuery(service: service, entryID: entryID, dataProtection: false) as CFDictionary)
        return ok && (s2 == errSecSuccess || s2 == errSecItemNotFound)
    }

    private static func wipeService(_ service: String) {
        func wipe(dataProtection: Bool) {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
            SecItemDelete(q as CFDictionary)
        }
        if dp { wipe(dataProtection: true) }
        wipe(dataProtection: false)
    }
}
