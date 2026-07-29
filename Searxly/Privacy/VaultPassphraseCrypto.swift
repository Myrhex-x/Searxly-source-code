//
//  VaultPassphraseCrypto.swift
//  Searxly
//
//  PBKDF2-HMAC-SHA256 verifier for the optional vault passphrase.
//  Stores only salt + derived hash in AppData — never the passphrase itself.
//

import Foundation
import Security
import CommonCrypto

nonisolated enum VaultPassphraseCrypto: Sendable {
    private static let saltLength = 16
    private static let verifierLength = 32

    /// Work factor for verifiers written from now on. OWASP's current floor for PBKDF2-HMAC-SHA256.
    /// Measured at ~90 ms on Apple Silicon, which is the whole cost budget for one unlock attempt.
    static let currentIterations = 600_000

    /// What shipped before the bump. Verifiers stored without an explicit count were written at this
    /// value, so they must keep verifying at it — see `PasswordVaultManager.verifyPassphrase`, which
    /// re-derives at `currentIterations` once the old passphrase checks out.
    static let legacyIterations = 150_000

    static func generateSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        guard status == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func deriveVerifier(passphrase: String, salt: Data, iterations: Int = currentIterations) -> Data? {
        guard !passphrase.isEmpty, salt.count >= saltLength, iterations > 0 else { return nil }
        return try? pbkdf2(
            password: Data(passphrase.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: verifierLength
        )
    }

    static func verify(passphrase: String, salt: Data, verifier: Data, iterations: Int = currentIterations) -> Bool {
        guard let derived = deriveVerifier(passphrase: passphrase, salt: salt, iterations: iterations) else { return false }
        return derived.count == verifier.count
            && derived.withUnsafeBytes { d in
                verifier.withUnsafeBytes { v in
                    timingsafe_bcmp(d.baseAddress, v.baseAddress, verifier.count) == 0
                }
            }
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var derivedKey = Data(count: keyLength)
        let result = derivedKey.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw NSError(domain: "VaultPassphraseCrypto", code: Int(result))
        }
        return derivedKey
    }
}