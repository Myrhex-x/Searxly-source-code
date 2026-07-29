//
//  TOTPGeneratorTests.swift
//  SearxlyTests
//
//  Conformance tests for the vault's two-factor engine.
//
//  The generation tests are the published RFC 6238 Appendix B vectors. They matter more than
//  usual here: a TOTP bug is invisible in normal use (a wrong code just looks like "the site
//  rejected it") and there is no server round-trip to catch it, so the spec vectors are the only
//  real proof the engine is correct.
//

import XCTest
@testable import Searxly

final class TOTPGeneratorTests: XCTestCase {

    // RFC 6238 seeds: ASCII "12345678901234567890", extended per algorithm.
    private let sha1Seed = Data("12345678901234567890".utf8)
    private let sha256Seed = Data("12345678901234567890123456789012".utf8)
    private let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private func makeConfiguration(
        secret: Data,
        algorithm: TOTPConfiguration.Algorithm
    ) -> TOTPConfiguration {
        TOTPConfiguration(secret: secret, algorithm: algorithm, digits: 8, period: 30)
    }

    private func code(_ configuration: TOTPConfiguration, at unixTime: TimeInterval) -> String? {
        TOTPGenerator.code(for: configuration, at: Date(timeIntervalSince1970: unixTime))
    }

    // MARK: - RFC 6238 Appendix B vectors

    func testRFC6238VectorsSHA1() {
        let configuration = makeConfiguration(secret: sha1Seed, algorithm: .sha1)
        XCTAssertEqual(code(configuration, at: 59), "94287082")
        XCTAssertEqual(code(configuration, at: 1111111109), "07081804")
        XCTAssertEqual(code(configuration, at: 1111111111), "14050471")
        XCTAssertEqual(code(configuration, at: 1234567890), "89005924")
        XCTAssertEqual(code(configuration, at: 2000000000), "69279037")
        XCTAssertEqual(code(configuration, at: 20000000000), "65353130")
    }

    func testRFC6238VectorsSHA256() {
        let configuration = makeConfiguration(secret: sha256Seed, algorithm: .sha256)
        XCTAssertEqual(code(configuration, at: 59), "46119246")
        XCTAssertEqual(code(configuration, at: 1111111109), "68084774")
        XCTAssertEqual(code(configuration, at: 1111111111), "67062674")
        XCTAssertEqual(code(configuration, at: 1234567890), "91819424")
        XCTAssertEqual(code(configuration, at: 2000000000), "90698825")
        XCTAssertEqual(code(configuration, at: 20000000000), "77737706")
    }

    func testRFC6238VectorsSHA512() {
        let configuration = makeConfiguration(secret: sha512Seed, algorithm: .sha512)
        XCTAssertEqual(code(configuration, at: 59), "90693936")
        XCTAssertEqual(code(configuration, at: 1111111109), "25091201")
        XCTAssertEqual(code(configuration, at: 1111111111), "99943326")
        XCTAssertEqual(code(configuration, at: 1234567890), "93441116")
        XCTAssertEqual(code(configuration, at: 2000000000), "38618901")
        XCTAssertEqual(code(configuration, at: 20000000000), "47863826")
    }

    /// The 6-digit case every real site actually uses is the low 6 digits of the 8-digit vector.
    func testSixDigitCodeIsTruncationOfEightDigit() {
        let eight = makeConfiguration(secret: sha1Seed, algorithm: .sha1)
        var six = eight
        six.digits = 6
        XCTAssertEqual(code(six, at: 59), "287082")
        XCTAssertEqual(code(six, at: 1234567890), "005924")
    }

    func testCodeIsStableWithinAPeriodAndChangesAcross() {
        let configuration = makeConfiguration(secret: sha1Seed, algorithm: .sha1)
        // 30-second window starting at t=30.
        XCTAssertEqual(code(configuration, at: 30), code(configuration, at: 59))
        XCTAssertNotEqual(code(configuration, at: 59), code(configuration, at: 60))
    }

    // MARK: - Countdown

    func testSecondsRemainingSpansTheFullPeriod() {
        let configuration = makeConfiguration(secret: sha1Seed, algorithm: .sha1)
        // At t=30 a fresh window opens, so a full period remains.
        XCTAssertEqual(TOTPGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 30)), 30)
        XCTAssertEqual(TOTPGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 45)), 15)
        // Never reports 0 — a "0s" label would read as expired while the code is still valid.
        XCTAssertEqual(TOTPGenerator.secondsRemaining(for: configuration, at: Date(timeIntervalSince1970: 59)), 1)
    }

    func testProgressRunsZeroToOneAcrossThePeriod() {
        let configuration = makeConfiguration(secret: sha1Seed, algorithm: .sha1)
        XCTAssertEqual(TOTPGenerator.progress(for: configuration, at: Date(timeIntervalSince1970: 30)), 0, accuracy: 0.001)
        XCTAssertEqual(TOTPGenerator.progress(for: configuration, at: Date(timeIntervalSince1970: 45)), 0.5, accuracy: 0.001)
    }

    // MARK: - Base32

    /// RFC 4648 §10 test vectors.
    func testBase32RoundTrip() {
        let cases: [(String, String)] = [
            ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"),
            ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")
        ]
        for (plain, encoded) in cases {
            XCTAssertEqual(TOTPGenerator.base32Encode(Data(plain.utf8)), encoded, "encoding \(plain)")
            XCTAssertEqual(TOTPGenerator.base32Decode(encoded), Data(plain.utf8), "decoding \(encoded)")
        }
    }

    /// Sites print secrets lowercased, space-separated, hyphenated, or padded — all must decode.
    func testBase32ToleratesRealWorldFormatting() {
        let canonical = TOTPGenerator.base32Decode("MZXW6YTBOI")
        XCTAssertNotNil(canonical)
        XCTAssertEqual(TOTPGenerator.base32Decode("mzxw6ytboi"), canonical)
        XCTAssertEqual(TOTPGenerator.base32Decode("MZXW 6YTB OI"), canonical)
        XCTAssertEqual(TOTPGenerator.base32Decode("MZXW-6YTB-OI"), canonical)
        XCTAssertEqual(TOTPGenerator.base32Decode("MZXW6YTBOI======"), canonical)
    }

    func testBase32RejectsInvalidInput() {
        XCTAssertNil(TOTPGenerator.base32Decode(""))
        XCTAssertNil(TOTPGenerator.base32Decode("!!!!"))
        // 0, 1 and 8 are deliberately absent from the RFC 4648 alphabet.
        XCTAssertNil(TOTPGenerator.base32Decode("MZXW0YTB"))
    }

    // MARK: - otpauth:// parsing

    func testParsesFullURI() {
        let configuration = TOTPGenerator.parse(
            "otpauth://totp/GitHub:nathan@example.com?secret=MZXW6YTBOI&issuer=GitHub&algorithm=SHA256&digits=8&period=60"
        )
        XCTAssertEqual(configuration?.secret, Data("foobar".utf8))
        XCTAssertEqual(configuration?.algorithm, .sha256)
        XCTAssertEqual(configuration?.digits, 8)
        XCTAssertEqual(configuration?.period, 60)
        XCTAssertEqual(configuration?.issuer, "GitHub")
        XCTAssertEqual(configuration?.account, "nathan@example.com")
    }

    func testParsesURIWithDefaults() {
        let configuration = TOTPGenerator.parse("otpauth://totp/Example?secret=MZXW6YTBOI")
        XCTAssertEqual(configuration?.algorithm, .sha1)
        XCTAssertEqual(configuration?.digits, 6)
        XCTAssertEqual(configuration?.period, 30)
        XCTAssertEqual(configuration?.account, "Example")
    }

    /// The `issuer` parameter is authoritative when it disagrees with the label prefix.
    func testIssuerParameterWinsOverLabelPrefix() {
        let configuration = TOTPGenerator.parse("otpauth://totp/Old:me@example.com?secret=MZXW6YTBOI&issuer=New")
        XCTAssertEqual(configuration?.issuer, "New")
        XCTAssertEqual(configuration?.account, "me@example.com")
    }

    func testParsesBareBase32Secret() {
        let configuration = TOTPGenerator.parse("MZXW 6YTB OI")
        XCTAssertEqual(configuration?.secret, Data("foobar".utf8))
        XCTAssertEqual(configuration?.digits, 6)
        XCTAssertEqual(configuration?.period, 30)
    }

    func testRejectsUnusableInput() {
        XCTAssertNil(TOTPGenerator.parse(""))
        XCTAssertNil(TOTPGenerator.parse("   "))
        XCTAssertNil(TOTPGenerator.parse("otpauth://totp/Example"), "missing secret")
        XCTAssertNil(TOTPGenerator.parse("otpauth://totp/Example?secret=!!!"), "invalid base32")
        // Counter-based HOTP needs per-use counter state we do not keep; better to refuse it than
        // to silently generate time-based codes that will never validate.
        XCTAssertNil(TOTPGenerator.parse("otpauth://hotp/Example?secret=MZXW6YTBOI&counter=1"))
    }

    /// Out-of-range values fall back to the RFC defaults rather than producing unusable codes.
    func testClampsAbsurdDigitsAndPeriod() {
        let configuration = TOTPGenerator.parse("otpauth://totp/Example?secret=MZXW6YTBOI&digits=99&period=0")
        XCTAssertEqual(configuration?.digits, 6)
        XCTAssertEqual(configuration?.period, 30)
    }

    // MARK: - URI round-trip (this is the on-disk format, so it must be lossless)

    func testURIRoundTripPreservesEverything() {
        let original = TOTPConfiguration(
            secret: Data("foobar".utf8),
            algorithm: .sha512,
            digits: 7,
            period: 45,
            issuer: "Example Inc",
            account: "me@example.com"
        )
        let parsed = TOTPGenerator.parse(TOTPGenerator.uri(for: original))
        XCTAssertEqual(parsed, original)
    }

    func testURIRoundTripWithoutLabels() {
        let original = TOTPConfiguration(secret: Data("foobar".utf8))
        let parsed = TOTPGenerator.parse(TOTPGenerator.uri(for: original))
        XCTAssertEqual(parsed?.secret, original.secret)
        XCTAssertEqual(parsed?.algorithm, original.algorithm)
        XCTAssertEqual(parsed?.digits, original.digits)
        XCTAssertEqual(parsed?.period, original.period)
    }

    /// Codes must survive the storage round-trip unchanged — this is what actually breaks if the
    /// URI encoder and parser ever drift apart.
    func testCodesMatchAcrossURIRoundTrip() {
        let original = TOTPConfiguration(secret: sha256Seed, algorithm: .sha256, digits: 8, period: 30)
        guard let parsed = TOTPGenerator.parse(TOTPGenerator.uri(for: original)) else {
            return XCTFail("round-tripped URI failed to parse")
        }
        XCTAssertEqual(code(parsed, at: 1111111109), "68084774")
    }

    // MARK: - Vault entry decoding

    /// The vault store drops entries whose decode throws, so a pre-TOTP JSON entry MUST still
    /// decode — otherwise shipping this feature would erase every existing login on first read.
    func testLegacyEntryWithoutTOTPFieldStillDecodes() throws {
        let legacy = """
        {"id":"6E7B0F1C-9A5D-4E2F-8B3A-1C2D3E4F5A6B","domain":"example.com",
         "username":"me@example.com","dateAdded":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(PasswordVaultEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(entry.domain, "example.com")
        XCTAssertFalse(entry.hasTOTP)
    }

    func testEntryRoundTripsTOTPFlag() throws {
        let entry = PasswordVaultEntry(domain: "example.com", username: "me", notes: "hi", hasTOTP: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PasswordVaultEntry.self, from: try encoder.encode(entry))

        XCTAssertTrue(decoded.hasTOTP)
        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.domain, entry.domain)
        XCTAssertEqual(decoded.username, entry.username)
        XCTAssertEqual(decoded.notes, entry.notes)
        // Deliberately field-by-field rather than whole-struct: `.iso8601` encodes to whole
        // seconds, so a decoded `dateAdded` is never exactly equal to the original Date. That is
        // fine for the store (it truncates once and stays stable) but makes `==` useless here.
        XCTAssertEqual(decoded.dateAdded.timeIntervalSince1970,
                       entry.dateAdded.timeIntervalSince1970, accuracy: 1.0)
    }
}
