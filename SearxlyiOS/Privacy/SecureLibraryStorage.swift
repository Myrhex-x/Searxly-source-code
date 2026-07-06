//
//  SecureLibraryStorage.swift
//  SearxlyiOS
//
//  Encrypted-at-rest persistence for the iOS library (bookmarks + history) — the iOS
//  expression of the macOS EncryptedDataStore/DataEncryptor/KeychainManager stack.
//
//  Same wire format as macOS ("SENC" magic + 1-byte version + AES-GCM combined blob) so the
//  two implementations stay convergible, but always-on: iOS has no encryption toggle. The key
//  is a device-only 256-bit key in the data-protection Keychain (never iCloud-synced), and
//  writes are synchronous + atomic with complete file protection — matching the project rule
//  that persistence never defers durability (quick-quit data loss).
//

import Foundation
import CryptoKit
import Security

enum SecureLibraryStorage {

    enum StorageError: Error {
        case keyUnavailable
        case invalidData
        case decryptionFailed
    }

    private static let currentVersion: UInt8 = 1
    private static let magic = Data("SENC".utf8)

    // MARK: - File location

    /// Application Support/Searxly/Library.enc
    static func fileURL(name: String = "Library.enc") -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Searxly", isDirectory: true)
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent(name)
    }

    // MARK: - Load / save

    /// Decodes the encrypted file, or nil when it doesn't exist / can't be read.
    /// An unreadable (corrupt or key-lost) file is quarantined rather than deleted, so a future
    /// fix can still recover it — mirrors the macOS "AppData.json.broken-*" behavior.
    static func load<T: Decodable>(_ type: T.Type, from url: URL = fileURL()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let raw = try Data(contentsOf: url)
            let plaintext = try decrypt(raw, using: loadOrCreateKey())
            return try JSONDecoder().decode(T.self, from: plaintext)
        } catch {
            quarantine(url)
            return nil
        }
    }

    /// Encrypts and writes synchronously (atomic + complete file protection).
    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL = fileURL()) -> Bool {
        do {
            let plaintext = try JSONEncoder().encode(value)
            let sealed = try encrypt(plaintext, using: loadOrCreateKey())
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    static func erase(url: URL = fileURL()) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - AES-GCM envelope (same format as macOS DataEncryptor)

    static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else { throw StorageError.invalidData }
        var result = magic
        result.append(currentVersion)
        result.append(combined)
        return result
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        // "SENC" (4) + version (1) + nonce (12) + tag (16) + ≥1 byte ciphertext
        guard data.count >= 34, data.prefix(4) == magic, data[4] == currentVersion else {
            throw StorageError.invalidData
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(5))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw StorageError.decryptionFailed
        }
    }

    // MARK: - Keychain key (device-only, data-protection keychain)

    private static let service = "com.searxly.ios.encryption"
    private static let account = "library-encryption-key"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        var add = baseQuery()
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = loadKey() { return raced }
        guard status == errSecSuccess else { throw StorageError.keyUnavailable }
        return key
    }

    private static func loadKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func deleteKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Quarantine

    private static func quarantine(_ url: URL) {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".broken-\(ts)")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
