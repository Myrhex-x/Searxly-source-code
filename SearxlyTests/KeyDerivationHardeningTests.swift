//
//  KeyDerivationHardeningTests.swift
//  SearxlyTests
//
//  Locks in the PBKDF2 work factors and, just as importantly, the migration paths that let data
//  written at the OLD work factors keep opening. A regression here is silent in normal use — the
//  app still encrypts and decrypts fine, it just does so with a weaker KDF, or it locks a user out
//  of a vault/backup they can still remember the password for. Neither shows up without a test.
//

import XCTest
import CryptoKit
import CommonCrypto
@testable import Searxly

final class KeyDerivationHardeningTests: XCTestCase {

    /// OWASP's current floor for PBKDF2-HMAC-SHA256. Every site below derives at least this much.
    private let owaspFloor = 600_000

    /// `WalletBackup.restore` gates on the BIP-39 checksum, so the round-trip has to use a genuinely
    /// valid mnemonic — the canonical all-zero-entropy vector — or a passing test proves nothing.
    private static let validMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        .split(separator: " ").map(String.init)

    // MARK: - Vault passphrase

    func testVaultVerifierUsesOWASPFloor() {
        XCTAssertGreaterThanOrEqual(VaultPassphraseCrypto.currentIterations, owaspFloor,
                                    "vault passphrase KDF dropped below the OWASP floor")
    }

    func testVaultLegacyVerifierStillAcceptsAtItsRecordedCount() throws {
        let salt = try XCTUnwrap(VaultPassphraseCrypto.generateSalt())
        let passphrase = "a-real-user-passphrase"

        let legacy = try XCTUnwrap(VaultPassphraseCrypto.deriveVerifier(
            passphrase: passphrase, salt: salt,
            iterations: VaultPassphraseCrypto.legacyIterations))

        // Someone who set a passphrase before the bump must still get in.
        XCTAssertTrue(VaultPassphraseCrypto.verify(
            passphrase: passphrase, salt: salt, verifier: legacy,
            iterations: VaultPassphraseCrypto.legacyIterations))

        // And this is exactly why the count has to be stored alongside the verifier: check the same
        // verifier at the new count and it fails. Drop the stored count and every pre-bump user is
        // locked out of their own vault.
        XCTAssertFalse(VaultPassphraseCrypto.verify(
            passphrase: passphrase, salt: salt, verifier: legacy))
    }

    func testVaultUpgradedVerifierDiffersAndVerifies() throws {
        let salt = try XCTUnwrap(VaultPassphraseCrypto.generateSalt())
        let passphrase = "a-real-user-passphrase"

        let legacy = try XCTUnwrap(VaultPassphraseCrypto.deriveVerifier(
            passphrase: passphrase, salt: salt,
            iterations: VaultPassphraseCrypto.legacyIterations))
        let upgraded = try XCTUnwrap(VaultPassphraseCrypto.deriveVerifier(
            passphrase: passphrase, salt: salt))

        XCTAssertNotEqual(legacy, upgraded, "raising the work factor must change the verifier")
        XCTAssertTrue(VaultPassphraseCrypto.verify(passphrase: passphrase, salt: salt, verifier: upgraded))
        XCTAssertFalse(VaultPassphraseCrypto.verify(passphrase: "wrong", salt: salt, verifier: upgraded))
    }

    func testVaultLockConfigWithoutRecordedCountDecodesAsLegacy() {
        // A config persisted before `customIterations` existed has no such key. It must decode to the
        // legacy count, NOT the current one — defaulting the other way locks those users out.
        let json = Data(#"{"useCustomPassword":true,"autoLockMinutes":10}"#.utf8)
        let decoded = try? JSONDecoder().decode(PasswordVaultData.self, from: json)
        XCTAssertNil(decoded?.customIterations,
                     "a pre-bump config carries no work factor; loadLockConfig supplies the legacy default")
    }

    // MARK: - Wallet seed backup

    func testWalletBackupExportsAtOWASPFloorAndRoundTrips() throws {
        let words = Self.validMnemonic
        let password = "a-long-enough-backup-password"

        let file = try XCTUnwrap(WalletBackup.export(words: words, password: password))
        XCTAssertEqual(WalletBackup.restore(fileData: file, password: password), words)
        XCTAssertNil(WalletBackup.restore(fileData: file, password: "wrong"))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(json["rounds"] as? Int), owaspFloor,
                                    "wallet backup KDF dropped below the OWASP floor")
    }

    func testWalletBackupRejectsDowngradedRounds() throws {
        // `rounds` is read back out of the file, so it is attacker-controlled. A file claiming a
        // trivially-crackable KDF must be refused rather than honoured.
        let words = Self.validMnemonic
        let password = "a-long-enough-backup-password"
        let file = try XCTUnwrap(WalletBackup.export(words: words, password: password))

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        json["rounds"] = 1
        let downgraded = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(WalletBackup.restore(fileData: downgraded, password: password),
                     "a rounds=1 file must be rejected, not honoured")
    }

    func testWalletBackupRejectsAbsurdRoundsWithoutHanging() throws {
        // And the other end: an absurd count must be refused up front rather than sent into a
        // multi-hour derivation that wedges the app.
        let words = Self.validMnemonic
        let password = "a-long-enough-backup-password"
        let file = try XCTUnwrap(WalletBackup.export(words: words, password: password))

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        json["rounds"] = 2_000_000_000
        let absurd = try JSONSerialization.data(withJSONObject: json)

        let started = Date()
        XCTAssertNil(WalletBackup.restore(fileData: absurd, password: password))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "an absurd rounds value must be rejected up front, not attempted")
    }

    func testWalletBackupStillRestoresLegacy200kFile() throws {
        // Built byte-for-byte the way the pre-bump build wrote it. Existing user backups must open.
        let words = Self.validMnemonic
        let password = "an-older-backup-password"

        var salt = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, 16, &salt), errSecSuccess)

        var derived = [UInt8](repeating: 0, count: 32)
        Data(salt).withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, 16,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &derived, 32)
        }
        let sealed = try XCTUnwrap(try AES.GCM.seal(Data(words.joined(separator: " ").utf8),
                                                    using: SymmetricKey(data: Data(derived))).combined)
        let legacyFile = try JSONSerialization.data(withJSONObject: [
            "version": 1, "kdf": "pbkdf2-sha256", "rounds": 200_000,
            "salt": Data(salt).base64EncodedString(), "cipher": "aes-256-gcm",
            "data": sealed.base64EncodedString(),
        ])

        XCTAssertEqual(WalletBackup.restore(fileData: legacyFile, password: password), words,
                       "a genuine 200k-era backup must still restore")
    }

    // MARK: - App backup envelope

    func testAppBackupWritesFormatVersion2() throws {
        // The envelope's version byte is what tells a restore which work factor to derive at, so it
        // has to advance when the work factor does. (Read-only w.r.t. app state: createBackup only
        // reads persistence; restore is deliberately not exercised here.)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kdf-envelope-\(UUID().uuidString).searxlybackup")
        defer { try? FileManager.default.removeItem(at: destination) }

        try BackupManager.createBackup(to: destination, password: "a-backup-password", includeKey: false)
        let bytes = try Data(contentsOf: destination)

        XCTAssertEqual(bytes.prefix(4), Data("SBKP".utf8))
        XCTAssertEqual(bytes[4], 2, "envelope version must advance with the work factor")
    }
}
