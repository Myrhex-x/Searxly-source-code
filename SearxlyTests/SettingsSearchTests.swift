//
//  SettingsSearchTests.swift
//  SearxlyTests
//
//  Pins the Settings search index: ranking (title prefix beats keyword hits), the short-query
//  guard, and — the invariant that matters — every entry navigates to a pane that actually exists
//  in this edition's sidebar, so search can never strand the user on a missing category.
//

import XCTest
@testable import Searxly

final class SettingsSearchTests: XCTestCase {

    func testEveryEntryNavigatesToAPaneInThisEditionsSidebar() {
        let reachable = Set(SettingsSidebarGroup.allCases.flatMap(\.categories))
        for entry in SettingsSearchIndex.entries {
            XCTAssertTrue(reachable.contains(entry.category),
                          "“\(entry.title)” points at \(entry.category.rawValue), which is not in this edition's sidebar")
        }
    }

    func testTitlePrefixOutranksKeywordMatches() {
        let results = SettingsSearchIndex.search("clear")
        XCTAssertEqual(results.first?.title, "Clear browsing data")
    }

    func testKeywordSearchFindsRenamedConcepts() {
        // People type what they want, not the label: "wipe" should land on Clear browsing data.
        XCTAssertTrue(SettingsSearchIndex.search("wipe").contains { $0.title == "Clear browsing data" })
        XCTAssertTrue(SettingsSearchIndex.search("incognito").contains { $0.title == "Private tabs by default" })
    }

    func testShortAndUnmatchedQueriesReturnNothing() {
        XCTAssertTrue(SettingsSearchIndex.search("c").isEmpty, "single characters must not spray results")
        XCTAssertTrue(SettingsSearchIndex.search("zzqx").isEmpty)
    }

    func testResultsAreCapped() {
        // A broad term must not overwhelm the panel.
        XCTAssertLessThanOrEqual(SettingsSearchIndex.search("se").count, 8)
    }
}
