//
//  BackupManager.swift
//  Searxly
//
//  Encrypted backup and restore for the entire app state.
//  Produces a single portable .searxlybackup file that contains the AppData
//  (history, bookmarks, instances, etc.) plus optionally the encryption key,
//  all protected by a strong user password.
//
//  This is the recommended way to migrate or back up Searxly.
//

import Foundation
import CryptoKit
import CommonCrypto

enum BackupManager {

    enum BackupError: LocalizedError {
        case noData
        case invalidPassword
        case corruptedBackup
        case keyMissing
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noData: return "No data available to back up."
            case .invalidPassword: return "The password was incorrect or the backup is corrupted."
            case .corruptedBackup: return "This backup file is corrupted or was created by a newer version of Searxly."
            case .keyMissing: return "Encryption is enabled but no key is available in the Keychain."
            case .writeFailed: return "Failed to write the backup file."
            }
        }
    }

    // MARK: - Public API

    /// Creates an encrypted backup file at the given URL.
    /// - Parameter destination: Where to save the .searxlybackup file.
    /// - Parameter password: Strong password chosen by the user.
    /// - Parameter includeKey: Whether to also embed the current encryption key (allows full restore including key).
    static func createBackup(to destination: URL, password: String, includeKey: Bool = true) throws {
        let appData = Persistence.load()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let dataBlob = try encoder.encode(appData)

        var keyData: Data?
        if includeKey, let key = KeychainManager.loadKey() {
            keyData = key
        }

        let backup = EncryptedBackup(
            version: 1,
            timestamp: Date(),
            appData: dataBlob,
            encryptionKey: keyData
        )

        let payload = try backup.encryptedPayload(using: password)
        try payload.write(to: destination, options: .atomic)
    }

    /// Restores from an encrypted backup file.
    /// - Parameter source: The .searxlybackup file.
    /// - Parameter password: The password used when the backup was created.
    /// - Returns: Whether the encryption key was also restored.
    @discardableResult
    static func restore(from source: URL, password: String) throws -> Bool {
        // A backup file picked via NSOpenPanel may be a security-scoped URL when sandboxed; without
        // this, the read can fail. Harmless (returns false) when the app isn't sandboxed.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard !password.isEmpty else { throw BackupError.invalidPassword }
        let payload = try Data(contentsOf: source)

        let backup = try EncryptedBackup.decrypted(from: payload, using: password)

        // Restore the main data
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restoredData = try decoder.decode(AppData.self, from: backup.appData)

        // Write it through the normal path (respects current encryption setting)
        Persistence.save(restoredData)
        EncryptionRecoveryManager.shared.clearRecoveryState()

        var keyWasRestored = false

        // Optionally restore the encryption key into Keychain
        if let embeddedKey = backup.encryptionKey {
            _ = KeychainManager.saveKey(embeddedKey)
            keyWasRestored = true

            // If the user had encryption off, we can turn it on now
            if !EncryptedDataStore.isEncryptionEnabled() {
                EncryptedDataStore.setEncryptionEnabled(true)
                PrivacyManager.shared.forceSetDataEncryptionEnabled(true)
            }
        }

        return keyWasRestored
    }

    // MARK: - Internal encrypted container

    private struct EncryptedBackup: Codable {
        let version: Int
        let timestamp: Date
        let appData: Data
        let encryptionKey: Data?   // optional

        /// Envelope version written by this build. v1 derived at 150k PBKDF2 rounds; v2 raised that to
        /// OWASP's current floor. The byte is what tells `decrypted(from:)` which count to use, so
        /// backups exported by older builds keep restoring — bump this, never re-use a version.
        static let currentFormatVersion: UInt8 = 2

        /// PBKDF2 work factor for a given envelope version. Unknown versions have no answer and must
        /// be rejected rather than guessed at.
        static func kdfIterations(forFormatVersion version: UInt8) -> Int? {
            switch version {
            case 1: return 150_000
            case 2: return 600_000
            default: return nil
            }
        }

        /// Encrypts the backup using a password (PBKDF2-HMAC-SHA256 + AES-GCM).
        func encryptedPayload(using password: String) throws -> Data {
            var saltBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
                throw BackupManager.BackupError.writeFailed
            }
            let salt = Data(saltBytes)
            let key = try Self.deriveKey(from: password, salt: salt,
                                         formatVersion: Self.currentFormatVersion)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(self)

            let sealed = try AES.GCM.seal(plaintext, using: key)

            // Format: "SBKP" + version (1 byte) + salt (16) + combined sealed box
            var result = Data("SBKP".utf8)
            result.append(Self.currentFormatVersion)
            result.append(salt)
            result.append(sealed.combined ?? Data())

            return result
        }

        static func decrypted(from payload: Data, using password: String) throws -> EncryptedBackup {
            // Normalize to a zero-based contiguous buffer so byte indexing/slicing is correct
            // regardless of the source Data's startIndex (slices and mmapped Data don't start at 0).
            let bytes = Data(payload)
            guard bytes.count > 22,
                  bytes.prefix(4) == Data("SBKP".utf8),
                  Self.kdfIterations(forFormatVersion: bytes[4]) != nil else {
                throw BackupError.corruptedBackup
            }
            let formatVersion = bytes[4]

            // Copy out of the slices so downstream APIs never see a non-zero startIndex.
            let salt = Data(bytes[5..<21])
            let ciphertext = Data(bytes[21...])

            let key = try Self.deriveKey(from: password, salt: salt, formatVersion: formatVersion)

            do {
                let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
                let plaintext = try AES.GCM.open(sealedBox, using: key)

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(EncryptedBackup.self, from: plaintext)
            } catch {
                throw BackupError.invalidPassword
            }
        }

        private static func deriveKey(from password: String, salt: Data,
                                      formatVersion: UInt8) throws -> SymmetricKey {
            guard let iterations = kdfIterations(forFormatVersion: formatVersion) else {
                throw BackupError.corruptedBackup
            }
            let passwordData = Data(password.utf8)
            let derived = try PBKDF2(
                password: passwordData,
                salt: salt,
                iterations: iterations,
                keyLength: 32
            )
            return SymmetricKey(data: derived)
        }
    }
}

// Minimal PBKDF2 implementation using CommonCrypto (via Security framework on Apple platforms).
//
// NOTE: an empty `Data`'s `withUnsafeBytes` buffer has a nil `baseAddress`, so the previous
// `baseAddress!` force-unwraps would TRAP (EXC_BREAKPOINT) on an empty password or salt instead of
// failing gracefully. We validate inputs up front and pass the (possibly nil) base addresses without
// force-unwrapping — `CCKeyDerivationPBKDF` takes implicitly-unwrapped optional pointers.
private func PBKDF2(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
    guard !password.isEmpty, !salt.isEmpty, keyLength > 0 else {
        throw BackupManager.BackupError.invalidPassword
    }
    var derivedKey = Data(count: keyLength)
    let result = derivedKey.withUnsafeMutableBytes { (derivedBytes: UnsafeMutableRawBufferPointer) -> Int32 in
        salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) -> Int32 in
            password.withUnsafeBytes { (passwordBytes: UnsafeRawBufferPointer) -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                    keyLength
                )
            }
        }
    }
    guard result == kCCSuccess else {
        throw BackupManager.BackupError.corruptedBackup  // Re-use existing error; derivation failure == unrecoverable for this backup
    }
    return derivedKey
}
