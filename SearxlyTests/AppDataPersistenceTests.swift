//
//  AppDataPersistenceTests.swift
//  SearxlyTests
//
//  Regression tests for AppData's Codable round-trip. AppData uses an EXPLICIT CodingKeys enum plus a
//  custom init(from:), so any stored property that isn't listed in CodingKeys is silently dropped on
//  encode AND ignored on decode — it works in memory for a session, then resets to its default on the
//  next launch. That's how appPrivacyMode / maxProtection regressed ("Maximum Privacy reverts to Normal
//  after quit"). These tests pin the persisted-settings surface so the next omission fails loudly here.
//

import XCTest
@testable import Searxly

final class AppDataPersistenceTests: XCTestCase {

    private func roundTrip(_ data: AppData) throws -> AppData {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppData.self, from: encoded)
    }

    /// The exact bug: a non-default privacy posture must survive an encode→decode cycle.
    func testAppPrivacyModeSurvivesRoundTrip() throws {
        var data = AppData()
        data.appPrivacyMode = .maximum
        data.maxProtection = .vpn

        let restored = try roundTrip(data)

        XCTAssertEqual(restored.appPrivacyMode, .maximum, "appPrivacyMode was dropped by encode/decode — check it's in CodingKeys")
        XCTAssertEqual(restored.maxProtection, .vpn, "maxProtection was dropped by encode/decode — check it's in CodingKeys")
    }

    /// The encrypted disk lane the app actually uses (CryptoKit envelope) must preserve the mode too —
    /// the same serializer runs, but this guards against an encrypt/decrypt regression specifically.
    func testAppPrivacyModeSurvivesEncryptedRoundTrip() throws {
        var data = AppData()
        data.appPrivacyMode = .encrypted

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(data)

        let key = DataEncryptor.generateKey()
        let sealed = try DataEncryptor.encrypt(plaintext, using: key)
        let opened = try DataEncryptor.decrypt(sealed, using: key)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AppData.self, from: opened)

        XCTAssertEqual(restored.appPrivacyMode, .encrypted)
    }

    /// A pre-feature file (no privacy keys) must decode to the privacy-neutral defaults, so upgrading
    /// users are never forced into an unexpected posture.
    func testMissingPrivacyKeysDecodeToDefaults() throws {
        let legacyJSON = "{}".data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppData.self, from: legacyJSON)

        XCTAssertEqual(decoded.appPrivacyMode, .normal)
        XCTAssertEqual(decoded.maxProtection, .tor)
    }

    /// Broad guard: a handful of representative persisted settings across sections must all survive a
    /// round-trip, so a future CodingKeys omission is caught regardless of which field it hits.
    func testRepresentativeSettingsSurviveRoundTrip() throws {
        var data = AppData()
        data.appPrivacyMode = .maximum
        data.maxProtection = .tor
        data.historyEnabled = true
        data.defaultNewTabsToPrivate = false
        data.knowledgePanelEnabled = true
        data.tabHibernationMaxActiveTabs = 3
        data.appLockEnabled = true

        let restored = try roundTrip(data)

        XCTAssertEqual(restored.appPrivacyMode, .maximum)
        XCTAssertEqual(restored.maxProtection, .tor)
        XCTAssertEqual(restored.historyEnabled, true)
        XCTAssertEqual(restored.defaultNewTabsToPrivate, false)
        XCTAssertEqual(restored.knowledgePanelEnabled, true)
        XCTAssertEqual(restored.tabHibernationMaxActiveTabs, 3)
        XCTAssertEqual(restored.appLockEnabled, true)
    }
}
