//
//  WalletBackup.swift
//  Searxly
//
//  Password-encrypted backup of the 12-word recovery phrase. Produces a small, self-describing JSON
//  file the user can store anywhere (USB, cloud, email) — it's useless without their password, so it
//  never exposes the seed the way a plaintext export would. Encryption: PBKDF2-SHA256 (200k) →
//  AES-256-GCM, matching the rest of the wallet's at-rest crypto.
//

import Foundation
import CryptoKit
import CommonCrypto

nonisolated enum WalletBackup {

    static let fileExtension = "searxlybackup"
    private static let currentVersion = 1
    private static let defaultRounds: UInt32 = 200_000

    /// On-disk format. Only salt + ciphertext are stored; the password is never written.
    private struct Payload: Codable {
        var version: Int
        var kdf: String          // "pbkdf2-sha256"
        var rounds: Int
        var salt: String         // base64 (per-backup random)
        var cipher: String       // "aes-256-gcm"
        var data: String         // base64 of AES-GCM combined (nonce || ciphertext || tag)
    }

    /// Encrypts the phrase under `password`. Returns the file bytes, or nil on bad input / RNG failure.
    static func export(words: [String], password: String) -> Data? {
        guard !words.isEmpty, !password.isEmpty else { return nil }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &salt) == errSecSuccess else { return nil }

        let key = deriveKey(password: password, salt: Data(salt), rounds: defaultRounds)
        let plaintext = Data(words.joined(separator: " ").utf8)
        guard let combined = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else { return nil }

        let payload = Payload(version: currentVersion, kdf: "pbkdf2-sha256", rounds: Int(defaultRounds),
                              salt: Data(salt).base64EncodedString(), cipher: "aes-256-gcm",
                              data: combined.base64EncodedString())
        return try? JSONEncoder().encode(payload)
    }

    /// Decrypts a backup file with `password`. Returns the words, or nil if the password is wrong, the
    /// file is malformed/tampered (GCM tag fails), or the decrypted phrase isn't a valid BIP-39 mnemonic.
    static func restore(fileData: Data, password: String) -> [String]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: fileData),
              let salt = Data(base64Encoded: payload.salt),
              let combined = Data(base64Encoded: payload.data) else { return nil }

        let key = deriveKey(password: password, salt: salt, rounds: UInt32(max(1, payload.rounds)))
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)),
              let phrase = String(data: plaintext, encoding: .utf8) else { return nil }

        let words = phrase.split(separator: " ").map(String.init)
        return BIP39.isValid(words) ? words : nil
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, 32)
        }
        return Data(derived)
    }
}
