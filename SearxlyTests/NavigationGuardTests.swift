//
//  NavigationGuardTests.swift
//  SearxlyTests
//
//  Pins the request-level shields' pure URL logic (ported from SearxlyiOS): tracking-parameter
//  stripping, HTTPS-only upgrade eligibility, and scheme classification. These run on every
//  navigation, so a regression would silently leak tracking IDs or downgrade connections.
//

import XCTest
@testable import Searxly

final class NavigationGuardTests: XCTestCase {

    private func strip(_ s: String) -> String? {
        NavigationGuard.strippingTrackingParams(from: URL(string: s)!)?.absoluteString
    }

    // MARK: - Tracking-parameter stripping

    func testStripsExactAndPrefixTrackers() {
        XCTAssertEqual(strip("https://example.com/p?fbclid=abc"), "https://example.com/p")
        XCTAssertEqual(strip("https://example.com/p?utm_source=x&utm_medium=y"), "https://example.com/p")
        XCTAssertEqual(strip("https://example.com/p?gclid=1&igshid=2"), "https://example.com/p")
    }

    func testKeepsLegitimateParamsAndOrder() {
        XCTAssertEqual(strip("https://example.com/s?q=privacy&utm_source=news&page=2"),
                       "https://example.com/s?q=privacy&page=2")
        // A URL with only real params is left untouched (nil = no change).
        XCTAssertNil(strip("https://example.com/s?q=privacy&page=2"))
    }

    func testTrackerCasingIsIgnored() {
        XCTAssertEqual(strip("https://example.com/p?FBCLID=abc&UTM_Source=x"), "https://example.com/p")
    }

    func testNoQueryOrNonWebLeavesURLUnchanged() {
        XCTAssertNil(strip("https://example.com/path"))
        XCTAssertNil(NavigationGuard.strippingTrackingParams(from: URL(string: "mailto:a@b.com?utm_source=x")!))
    }

    // MARK: - HTTPS-only

    func testUpgradesPlainHTTPToRealHosts() {
        XCTAssertTrue(NavigationGuard.shouldUpgradeToHTTPS(URL(string: "http://example.com")!))
        XCTAssertEqual(NavigationGuard.upgradedToHTTPS(URL(string: "http://example.com/p?q=1")!)?.absoluteString,
                       "https://example.com/p?q=1")
    }

    func testDoesNotUpgradeLoopbackLocalOrIP() {
        XCTAssertFalse(NavigationGuard.shouldUpgradeToHTTPS(URL(string: "http://localhost:8888/")!))
        XCTAssertFalse(NavigationGuard.shouldUpgradeToHTTPS(URL(string: "http://printer.local/")!))
        XCTAssertFalse(NavigationGuard.shouldUpgradeToHTTPS(URL(string: "http://192.168.1.10/")!))
        // Already-secure URLs are never "upgraded".
        XCTAssertFalse(NavigationGuard.shouldUpgradeToHTTPS(URL(string: "https://example.com/")!))
    }

    // MARK: - Scheme classification

    func testWebSchemeClassification() {
        XCTAssertTrue(NavigationGuard.isWebScheme(URL(string: "https://example.com")!))
        XCTAssertFalse(NavigationGuard.isWebScheme(URL(string: "mailto:a@b.com")!))
        XCTAssertFalse(NavigationGuard.isWebScheme(URL(string: "tel:123")!))
    }
}
