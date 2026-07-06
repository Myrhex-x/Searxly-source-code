//
//  EncryptionTests.swift
//  SearxlyTests
//
//  Smoke tests for DataEncryptor (AES-GCM round-trips, format detection, error paths).
//  To run: add a macOS Unit Testing Bundle target named "SearxlyTests" in Xcode,
//  set Host Application to Searxly, and add this file to the target.
//

import XCTest
import CryptoKit
@testable import Searxly

final class EncryptionTests: XCTestCase {

    // MARK: - Key generation

    func testGeneratedKeyIs32Bytes() {
        let key = DataEncryptor.generateKey()
        XCTAssertEqual(key.count, 32, "AES-256 key must be exactly 32 bytes")
    }

    func testGeneratedKeysAreUnique() {
        let k1 = DataEncryptor.generateKey()
        let k2 = DataEncryptor.generateKey()
        XCTAssertNotEqual(k1, k2, "Two generated keys should be different (entropy check)")
    }

    // MARK: - Round-trip

    func testEncryptDecryptRoundTrip() throws {
        let key = DataEncryptor.generateKey()
        let plaintext = "Searxly private search — no accounts, no cloud.".data(using: .utf8)!

        let ciphertext = try DataEncryptor.encrypt(plaintext, using: key)
        let recovered = try DataEncryptor.decrypt(ciphertext, using: key)

        XCTAssertEqual(recovered, plaintext)
    }

    func testRoundTripWithBinaryData() throws {
        let key = DataEncryptor.generateKey()
        let plaintext = Data((0..<256).map { UInt8($0) })

        let ciphertext = try DataEncryptor.encrypt(plaintext, using: key)
        let recovered = try DataEncryptor.decrypt(ciphertext, using: key)

        XCTAssertEqual(recovered, plaintext)
    }

    func testEmptyPayloadIsRejectedByDesign() throws {
        // The envelope intentionally requires ≥1 byte of ciphertext (see DataEncryptor.decrypt:
        // "Minimum … 1 ciphertext = 34 bytes"). Empty plaintext is therefore not a supported payload —
        // the app only ever encrypts non-empty JSON. This documents the real contract.
        let key = DataEncryptor.generateKey()
        let ciphertext = try DataEncryptor.encrypt(Data(), using: key)
        XCTAssertThrowsError(try DataEncryptor.decrypt(ciphertext, using: key),
                             "Decrypting an empty-plaintext envelope must be rejected by design")
    }

    // MARK: - Ciphertext structure

    func testEncryptedDataBeginsWithSENCMagic() throws {
        let key = DataEncryptor.generateKey()
        let ciphertext = try DataEncryptor.encrypt(Data("hello".utf8), using: key)

        let magic = ciphertext.prefix(4)
        XCTAssertEqual(magic, Data("SENC".utf8), "Envelope must start with SENC magic bytes")
    }

    func testEncryptedDataIsLargerThanPlaintext() throws {
        let key = DataEncryptor.generateKey()
        let plaintext = Data("test".utf8)
        let ciphertext = try DataEncryptor.encrypt(plaintext, using: key)

        // AES-GCM adds nonce (12) + tag (16) + SENC header (5) on top of plaintext
        XCTAssertGreaterThan(ciphertext.count, plaintext.count + 5)
    }

    func testEncryptSameInputProducesDifferentCiphertexts() throws {
        let key = DataEncryptor.generateKey()
        let plaintext = Data("determinism test".utf8)

        let c1 = try DataEncryptor.encrypt(plaintext, using: key)
        let c2 = try DataEncryptor.encrypt(plaintext, using: key)

        XCTAssertNotEqual(c1, c2, "AES-GCM must use a fresh random nonce each time")
    }

    // MARK: - Wrong key

    func testDecryptWithWrongKeyThrows() throws {
        let key1 = DataEncryptor.generateKey()
        let key2 = DataEncryptor.generateKey()
        let ciphertext = try DataEncryptor.encrypt(Data("secret".utf8), using: key1)

        XCTAssertThrowsError(try DataEncryptor.decrypt(ciphertext, using: key2)) { error in
            guard let enc = error as? DataEncryptor.EncryptionError else {
                return XCTFail("Expected EncryptionError, got \(error)")
            }
            XCTAssertEqual(enc, .decryptionFailed)
        }
    }

    // MARK: - Invalid key length

    func testEncryptWithShortKeyThrows() {
        let shortKey = Data(repeating: 0, count: 16)  // 128-bit, not 256-bit
        XCTAssertThrowsError(try DataEncryptor.encrypt(Data("x".utf8), using: shortKey)) { error in
            XCTAssertEqual(error as? DataEncryptor.EncryptionError, .invalidData)
        }
    }

    func testDecryptWithShortKeyThrows() throws {
        let key = DataEncryptor.generateKey()
        let ciphertext = try DataEncryptor.encrypt(Data("x".utf8), using: key)
        let shortKey = Data(repeating: 0, count: 16)

        XCTAssertThrowsError(try DataEncryptor.decrypt(ciphertext, using: shortKey)) { error in
            XCTAssertEqual(error as? DataEncryptor.EncryptionError, .keyNotAvailable)
        }
    }

    // MARK: - Corrupt ciphertext

    func testDecryptingCorruptDataThrows() throws {
        let key = DataEncryptor.generateKey()
        var ciphertext = try DataEncryptor.encrypt(Data("hello".utf8), using: key)
        // Flip a byte in the tag/payload area
        let flipIndex = ciphertext.count - 1
        ciphertext[flipIndex] ^= 0xFF

        XCTAssertThrowsError(try DataEncryptor.decrypt(ciphertext, using: key)) { error in
            XCTAssertEqual(error as? DataEncryptor.EncryptionError, .decryptionFailed)
        }
    }

    func testDecryptingEmptyDataThrows() {
        let key = DataEncryptor.generateKey()
        XCTAssertThrowsError(try DataEncryptor.decrypt(Data(), using: key)) { error in
            XCTAssertEqual(error as? DataEncryptor.EncryptionError, .invalidData)
        }
    }

    // MARK: - EncryptedDataStore format detection

    func testSENCEnvelopeIsDetectedAsEncrypted() throws {
        let key = DataEncryptor.generateKey()
        let ciphertext = try DataEncryptor.encrypt(Data("test".utf8), using: key)
        XCTAssertTrue(EncryptedDataStore.looksEncrypted(ciphertext),
                      "SENC-prefixed data must be detected as encrypted")
    }

    func testPlainJSONIsNotDetectedAsEncrypted() {
        let json = Data(#"{"historyEnabled":false}"#.utf8)
        XCTAssertFalse(EncryptedDataStore.looksEncrypted(json),
                       "Plain JSON must not be detected as encrypted")
    }

    func testEmptyDataIsNotDetectedAsEncrypted() {
        XCTAssertFalse(EncryptedDataStore.looksEncrypted(Data()))
    }
}
