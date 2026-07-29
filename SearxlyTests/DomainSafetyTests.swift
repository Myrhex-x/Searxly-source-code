//
//  DomainSafetyTests.swift
//  SearxlyTests
//
//  Pins the anti-spoofing display logic: homograph hosts must render as punycode, legitimate
//  international domains as friendly Unicode, and the registrable-domain split must isolate the
//  true site identity behind a subdomain trick.
//

import XCTest
@testable import Searxly

final class DomainSafetyTests: XCTestCase {

    private func display(_ s: String) -> String {
        DomainSafety.displayHost(for: URL(string: s)!)
    }

    // MARK: - Homograph policy

    func testCyrillicLookalikeFallsBackToPunycode() {
        // "аpple.com" with a Cyrillic а must NOT render as Latin "apple.com".
        let spoof = "https://\u{0430}pple.com/"
        XCTAssertEqual(display(spoof), "xn--pple-43d.com")
        XCTAssertFalse(display(spoof).contains("apple"))
    }

    func testMixedScriptLabelIsPunycode() {
        // Latin 'a' + Cyrillic 'р' + Latin 'ple' — a mixed-script label is a classic homograph.
        XCTAssertTrue(display("https://a\u{0440}ple.com/").hasPrefix("xn--"))
    }

    func testPlainASCIIUnchanged() {
        XCTAssertEqual(display("https://apple.com/path"), "apple.com")
        XCTAssertEqual(display("https://sub.example.co.uk/"), "sub.example.co.uk")
    }

    func testLegitimateAccentedLatinStaysUnicode() {
        // münchen.de is a single-script (Latin) host — should stay friendly Unicode, not punycode.
        XCTAssertEqual(display("https://m\u{00FC}nchen.de/"), "münchen.de")
    }

    func testSingleNonLatinScriptStaysUnicode() {
        // A pure-CJK host doesn't resemble Latin — safe to show as Unicode.
        XCTAssertEqual(display("https://\u{65E5}\u{672C}.jp/"), "日本.jp")
    }

    // MARK: - Registrable domain + emphasis

    func testRegistrableDomainHandlesMultiPartSuffixes() {
        XCTAssertEqual(DomainSafety.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainSafety.registrableDomain("www.apple.com"), "apple.com")
        XCTAssertEqual(DomainSafety.registrableDomain("alice.github.io"), "alice.github.io")
    }

    func testRegistrableDomainNilForIPAndSingleLabel() {
        XCTAssertNil(DomainSafety.registrableDomain("192.168.1.1"))
        XCTAssertNil(DomainSafety.registrableDomain("localhost"))
    }

    func testEmphasisSplitIsolatesTrueDomain() {
        // The subdomain trick: the eye reads "apple.com", but evil.ru is the real site.
        let split = DomainSafety.emphasisSplit(forHost: "apple.com.evil.ru")
        XCTAssertEqual(split.prefix, "apple.com.")
        XCTAssertEqual(split.registrable, "evil.ru")
    }

    func testEmphasisSplitPlainDomain() {
        let split = DomainSafety.emphasisSplit(forHost: "www.example.com")
        XCTAssertEqual(split.prefix, "www.")
        XCTAssertEqual(split.registrable, "example.com")
    }

    // MARK: - Executable download classification

    func testExecutableDownloadDetection() {
        XCTAssertTrue(AntiForensics.isExecutableDownload(URL(fileURLWithPath: "/x/Installer.dmg")))
        XCTAssertTrue(AntiForensics.isExecutableDownload(URL(fileURLWithPath: "/x/setup.pkg")))
        XCTAssertTrue(AntiForensics.isExecutableDownload(URL(fileURLWithPath: "/x/run.command")))
        XCTAssertFalse(AntiForensics.isExecutableDownload(URL(fileURLWithPath: "/x/photo.jpg")))
        XCTAssertFalse(AntiForensics.isExecutableDownload(URL(fileURLWithPath: "/x/report.pdf")))
    }
}
