//
//  PhishingGuardTests.swift
//  SearxlyTests
//
//  Pins the on-device phishing/malware blocklist matching: known-bad hosts and their subdomains are
//  flagged, unrelated hosts are not, and the enable flag gates the check.
//

import XCTest
@testable import Searxly

final class PhishingGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PhishingGuard.isEnabled = true
    }

    func testKnownMaliciousHostIsBlocked() {
        XCTAssertTrue(PhishingGuard.isBlocked(URL(string: "https://wicar.org/")!))
        XCTAssertTrue(PhishingGuard.isBlocked(URL(string: "https://testsafebrowsing.appspot.com/x")!))
    }

    func testSubdomainOfBlockedRegistrableIsBlocked() {
        // A subdomain of a listed registrable domain is also malicious.
        XCTAssertTrue(PhishingGuard.isBlocked(URL(string: "https://download.wicar.org/file")!))
    }

    func testUnrelatedHostIsAllowed() {
        XCTAssertFalse(PhishingGuard.isBlocked(URL(string: "https://apple.com/")!))
        XCTAssertFalse(PhishingGuard.isBlocked(URL(string: "https://example.org/")!))
    }

    func testDisablingGateSkipsTheCheck() {
        PhishingGuard.isEnabled = false
        XCTAssertFalse(PhishingGuard.isBlocked(URL(string: "https://wicar.org/")!))
        PhishingGuard.isEnabled = true
    }

    func testInterstitialOffersProceedWithMarker() {
        let url = URL(string: "https://wicar.org/test")!
        let html = PhishingGuard.interstitialHTML(for: url, host: "wicar.org")
        XCTAssertTrue(html.contains(PhishingGuard.proceedFragment), "must offer a consented proceed link")
        XCTAssertTrue(html.contains("wicar.org"))
    }
}
