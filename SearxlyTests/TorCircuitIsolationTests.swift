//
//  TorCircuitIsolationTests.swift
//  SearxlyTests
//
//  Pins the first-party keying that drives per-site Tor circuit rotation (Searxly Maximum):
//   1. The registrable-domain approximation — subdomains collapse to one party, multi-part
//      public suffixes (co.uk, github.io, …) don't swallow the site name, and IP literals /
//      loopback behave (loopback must NEVER count as a first party or claim a circuit).
//   2. The credential derivation — deterministic per (tab, site) so revisits reuse a circuit,
//      distinct across tabs and across sites so nothing shares one.
//

import XCTest
@testable import Searxly

final class TorCircuitIsolationTests: XCTestCase {

    private func key(_ urlString: String) -> String? {
        TorCircuitIsolation.firstPartyKey(for: URL(string: urlString)!)
    }

    // MARK: - First-party key

    func testSubdomainsCollapseToOneParty() {
        XCTAssertEqual(key("https://example.com/a"), "example.com")
        XCTAssertEqual(key("https://www.example.com/a"), "example.com")
        XCTAssertEqual(key("https://deep.sub.example.com/a?b=c"), "example.com")
    }

    func testMultiPartPublicSuffixesKeepTheSiteName() {
        XCTAssertEqual(key("https://shop.example.co.uk/x"), "example.co.uk")
        XCTAssertEqual(key("https://example.co.uk"), "example.co.uk")
        XCTAssertEqual(key("https://news.example.com.au"), "example.com.au")
        // Multi-tenant hosting: two different *.github.io sites are different parties.
        XCTAssertEqual(key("https://alice.github.io/repo"), "alice.github.io")
        XCTAssertEqual(key("https://bob.github.io"), "bob.github.io")
        XCTAssertNotEqual(key("https://alice.github.io"), key("https://bob.github.io"))
    }

    func testOnionAddressesKeyPerService() {
        let onion = String(repeating: "a", count: 56) + ".onion"
        XCTAssertEqual(key("http://\(onion)/page"), onion)
        XCTAssertEqual(key("http://www.\(onion)/page"), onion)
    }

    func testIPLiteralsAreTheirOwnParty() {
        XCTAssertEqual(key("http://192.168.1.10:8080/x"), "192.168.1.10")
        XCTAssertEqual(key("http://[2001:db8::2]/x"), "2001:db8::2")
    }

    func testLoopbackAndHostlessNeverClaimACircuit() {
        XCTAssertNil(key("http://127.0.0.1:8888/search?q=x"))
        XCTAssertNil(key("http://localhost:8888/"))
        XCTAssertNil(key("http://[::1]:8888/"))
        XCTAssertNil(key("about:blank"))
    }

    func testHostCasingIsNormalized() {
        XCTAssertEqual(key("https://WWW.Example.COM/x"), "example.com")
    }

    // MARK: - Credential derivation

    func testCredentialIsDeterministicPerTabAndSite() {
        let a = TorCircuitIsolation.credential(tabToken: "tab-1", site: "example.com")
        XCTAssertEqual(a, TorCircuitIsolation.credential(tabToken: "tab-1", site: "example.com"),
                       "revisiting a site in the same tab must map back to the same circuit")
        XCTAssertNotEqual(a, TorCircuitIsolation.credential(tabToken: "tab-2", site: "example.com"),
                          "the same site in two tabs must never share a circuit")
        XCTAssertNotEqual(a, TorCircuitIsolation.credential(tabToken: "tab-1", site: "other.net"),
                          "two sites in one tab must never share a circuit")
    }

    func testCredentialFitsTheSOCKSAuthField() {
        // RFC 1929 caps username/password at 255 bytes each.
        let cred = TorCircuitIsolation.credential(tabToken: UUID().uuidString, site: "example.com")
        XCTAssertLessThanOrEqual(cred.utf8.count, 255)
        XCTAssertFalse(cred.contains("example"), "the site name must not appear on the SOCKS wire")
    }
}
