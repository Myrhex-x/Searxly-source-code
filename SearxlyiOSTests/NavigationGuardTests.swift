//
//  NavigationGuardTests.swift
//  SearxlyiOSTests
//
//  Unit tests for the shields' pure URL logic (NavigationGuard) — the tracking-parameter stripper,
//  the De-AMP rewriter, and scheme classification — plus the widget's shared-count bridge. These are
//  deterministic, dependency-free functions, so they lock in the privacy behavior cheaply.
//
//  To run: create a Unit Testing Bundle target (see SearxlyiOS-EXTENSIONS.md) with SearxlyiOS as its
//  host app, then add this file to it. Everything here uses @testable import.
//

import XCTest
@testable import SearxlyiOS

final class NavigationGuardTests: XCTestCase {

    // MARK: - Tracking-parameter stripping

    func testStripsUTMParameters() {
        let url = URL(string: "https://example.com/article?utm_source=news&utm_medium=email&id=42")!
        XCTAssertEqual(NavigationGuard.strippingTrackingParams(from: url),
                       URL(string: "https://example.com/article?id=42"))
    }

    func testStripsKnownClickIDs() {
        let url = URL(string: "https://shop.example.com/p?fbclid=abc&gclid=xyz&color=blue")!
        XCTAssertEqual(NavigationGuard.strippingTrackingParams(from: url),
                       URL(string: "https://shop.example.com/p?color=blue"))
    }

    func testDropsQueryEntirelyWhenEverythingIsTracking() {
        let url = URL(string: "https://example.com/page?utm_source=x&fbclid=y")!
        XCTAssertEqual(NavigationGuard.strippingTrackingParams(from: url),
                       URL(string: "https://example.com/page"))
    }

    func testKeepsCleanURLUntouched() {
        let url = URL(string: "https://example.com/page?id=1&sort=asc")!
        XCTAssertNil(NavigationGuard.strippingTrackingParams(from: url))
    }

    func testIgnoresNonHTTPSchemes() {
        let url = URL(string: "ftp://example.com/x?utm_source=y")!
        XCTAssertNil(NavigationGuard.strippingTrackingParams(from: url))
    }

    // MARK: - De-AMP

    func testDeAMPGoogleSecureCache() {
        let url = URL(string: "https://www.google.com/amp/s/example.com/story")!
        XCTAssertEqual(NavigationGuard.deAMP(url), URL(string: "https://example.com/story"))
    }

    func testDeAMPProjectCache() {
        let url = URL(string: "https://example-com.cdn.ampproject.org/c/s/example.com/story")!
        XCTAssertEqual(NavigationGuard.deAMP(url), URL(string: "https://example.com/story"))
    }

    func testDeAMPReturnsNilForNormalURL() {
        XCTAssertNil(NavigationGuard.deAMP(URL(string: "https://example.com/normal-page")!))
    }

    // MARK: - Scheme classification

    func testWebSchemesAreHandledInApp() {
        XCTAssertTrue(NavigationGuard.isWebScheme(URL(string: "https://a.com")!))
        XCTAssertTrue(NavigationGuard.isWebScheme(URL(string: "http://a.com")!))
        XCTAssertTrue(NavigationGuard.isWebScheme(URL(string: "about:blank")!))
    }

    func testExternalSchemesAreNotWeb() {
        XCTAssertFalse(NavigationGuard.isWebScheme(URL(string: "tel:+15551234")!))
        XCTAssertFalse(NavigationGuard.isWebScheme(URL(string: "mailto:a@b.com")!))
        XCTAssertFalse(NavigationGuard.isWebScheme(URL(string: "sms:+15551234")!))
    }
}

final class SharedPrivacyStatsTests: XCTestCase {
    func testLifetimeBlockedRoundTrips() {
        SharedPrivacyStats.setLifetimeBlocked(4242)
        XCTAssertEqual(SharedPrivacyStats.lifetimeBlocked, 4242)
        SharedPrivacyStats.setLifetimeBlocked(0)
        XCTAssertEqual(SharedPrivacyStats.lifetimeBlocked, 0)
    }
}
