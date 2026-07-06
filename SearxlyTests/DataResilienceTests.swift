//
//  DataResilienceTests.swift
//  SearxlyTests
//
//  Regression tests for the at-rest data-loss fix: a single corrupt or schema-changed field in a
//  persisted file must degrade to a default instead of throwing and wiping ALL of the user's data.
//  Covers AppData (history/bookmarks/instances/…) and the isolated PasswordVault store (the saved-login
//  index whose loss would orphan the user's Keychain secrets).
//
//  To run: add a macOS Unit Testing Bundle target named "SearxlyTests" in Xcode, set its Host
//  Application to Searxly, and add this file to the target.
//

import XCTest
@testable import Searxly

final class DataResilienceTests: XCTestCase {

    // MARK: - AppData

    /// One corrupt sibling field (wrong type) must NOT take down the whole file — the other fields
    /// survive. This is the exact cascade that previously quarantined AppData.json and wiped state.
    func testAppDataPreservesValidFieldsWhenOneFieldIsCorrupt() throws {
        var data = AppData()
        data.bookmarks = [BookmarkItem(url: "https://example.com", title: "Example")]
        data.history   = [HistoryItem(url: "https://news.example", title: "News")]

        // Round-trip through the real encoder, then corrupt exactly one field in the JSON.
        let encoded = try JSONEncoder().encode(data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["history"] = "this is not an array"   // schema-changed / corrupt value
        let corrupted = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(AppData.self, from: corrupted)
        XCTAssertEqual(decoded.bookmarks.count, 1, "Valid bookmarks must survive a corrupt sibling field")
        XCTAssertEqual(decoded.history.count, 0, "Corrupt history degrades to empty, not a whole-file reset")
    }

    /// Older files missing newer keys must decode to sensible defaults (forward/backward compatibility).
    func testAppDataMissingKeysUseDefaults() throws {
        let empty = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppData.self, from: empty)
        XCTAssertTrue(decoded.history.isEmpty)
        XCTAssertTrue(decoded.bookmarks.isEmpty)
        XCTAssertTrue(decoded.defaultNewTabsToPrivate, "Privacy-first default must hold for legacy files")
    }

    // MARK: - PasswordVault

    /// One malformed saved-login entry must be skipped element-by-element; the rest still load. Losing
    /// the index would leave the corresponding Keychain secrets orphaned.
    func testVaultSkipsOneMalformedEntry() throws {
        var data = PasswordVaultData()
        data.entries = [
            PasswordVaultEntry(domain: "a.example", username: "alice"),
            PasswordVaultEntry(domain: "b.example", username: "bob")
        ]

        let encoded = try JSONEncoder().encode(data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        entries[0]["domain"] = 12345   // wrong type → first entry is undecodable
        json["entries"] = entries
        let corrupted = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(PasswordVaultData.self, from: corrupted)
        XCTAssertEqual(decoded.entries.count, 1, "The malformed entry is dropped; the rest survive")
        XCTAssertEqual(decoded.entries.first?.username, "bob")
    }

    /// A corrupt scalar field elsewhere in the vault file must degrade to its default, not discard the
    /// whole vault (which holds the login index).
    func testVaultToleratesCorruptScalarField() throws {
        var data = PasswordVaultData()
        data.entries = [PasswordVaultEntry(domain: "a.example", username: "alice")]
        data.autoLockMinutes = 7

        let encoded = try JSONEncoder().encode(data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["autoLockMinutes"] = "not a number"
        let corrupted = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(PasswordVaultData.self, from: corrupted)
        XCTAssertEqual(decoded.entries.count, 1, "Entries survive a corrupt unrelated scalar")
        XCTAssertEqual(decoded.autoLockMinutes, 10, "Corrupt scalar falls back to its default (10)")
    }
}
