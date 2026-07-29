//
//  WebPasskeyDirectoryTests.swift
//  SearxlyTests
//
//  Covers the DEGRADATION path of the system-passkey lookup — the half that can be tested here.
//
//  The restricted `web-browser.public-key-credential` entitlement is stripped from unsigned test
//  builds, so at runtime these tests always see the unauthorized case. That is precisely the case
//  worth pinning: whenever the entitlement isn't in force (Maximum today, any ad-hoc build, or a
//  user who declined), every passkey surface must vanish quietly instead of erroring, showing an
//  empty section, or claiming the user has no passkeys when we simply cannot see them.
//
//  Verifying the AUTHORIZED path requires a properly signed build of com.myrhex.Searxly and a real
//  passkey; it cannot be asserted from here.
//

import XCTest
import AuthenticationServices
@testable import Searxly

@MainActor
final class WebPasskeyDirectoryTests: XCTestCase {

    private var directory: WebPasskeyDirectory { WebPasskeyDirectory.shared }

    private var savedDisplayEnabled: Bool = true

    override func setUp() async throws {
        try await super.setUp()
        // The toggle is backed by UserDefaults in the host app — preserve the real value so
        // running tests can't silently change the developer's own setting.
        savedDisplayEnabled = directory.displayEnabled
    }

    override func tearDown() async throws {
        directory.displayEnabled = savedDisplayEnabled
        directory.invalidateCache()
        try await super.tearDown()
    }

    // MARK: - State

    func testAccessResolvesToAKnownStateWithoutCrashing() {
        directory.refreshAccess()
        XCTAssertTrue(
            [.unavailable, .notDetermined, .denied, .authorized].contains(directory.access),
            "access must always resolve to a known case"
        )
    }

    /// Without the entitlement the framework reports a non-authorized state, so nothing renders.
    func testUnsignedBuildIsNotActive() {
        directory.refreshAccess()
        XCTAssertNotEqual(directory.access, .authorized,
                          "a test build carries no restricted entitlement, so it cannot be authorized")
        XCTAssertFalse(directory.isActive)
    }

    // MARK: - Lookup degradation

    func testLookupReturnsEmptyWhenInactive() async {
        directory.refreshAccess()
        let result = await directory.passkeys(forDomain: "github.com")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyDomainIsRejected() async {
        let result = await directory.passkeys(forDomain: "")
        XCTAssertTrue(result.isEmpty)
    }

    /// nil (not []) while inactive: callers must be able to tell "we didn't look" apart from
    /// "there are none", so the UI never states an absence it can't actually observe.
    func testCachedLookupReportsUnknownRatherThanEmptyWhenInactive() {
        directory.refreshAccess()
        XCTAssertNil(directory.cachedPasskeys(forDomain: "github.com"))
    }

    func testTurningDisplayOffDeactivatesEvenIfAuthorized() {
        directory.displayEnabled = false
        XCTAssertFalse(directory.isActive, "the app-side switch must gate the surfaces on its own")
        XCTAssertNil(directory.cachedPasskeys(forDomain: "github.com"))
    }

    func testDisplayPreferenceRoundTrips() {
        directory.displayEnabled = false
        XCTAssertFalse(directory.displayEnabled)
        directory.displayEnabled = true
        XCTAssertTrue(directory.displayEnabled)
    }

    /// The system prompts once and a denial is permanent, so the UI must only offer the
    /// "enable" affordance while the answer is genuinely still open.
    func testAccessCanOnlyBeRequestedWhileUndecided() {
        directory.refreshAccess()
        XCTAssertEqual(directory.canRequestAccess, directory.access == .notDetermined)
    }

    // MARK: - Relying-party normalization

    /// Passkeys are keyed by bare registrable domain. These are the shapes the vault and the
    /// address bar actually hand over, and all must reduce to the RP id before lookup.
    func testDomainNormalizationMatchesRelyingPartyShape() {
        XCTAssertEqual(PasswordVaultManager.normalizeDomain("www.github.com"), "github.com")
        XCTAssertEqual(PasswordVaultManager.normalizeDomain("https://github.com/login"), "github.com")
        XCTAssertEqual(PasswordVaultManager.normalizeDomain("GitHub.com"), "github.com")
        XCTAssertEqual(PasswordVaultManager.normalizeDomain("github.com:443"), "github.com")
    }

    // MARK: - Summary shaping

    func testDisplayNamePrefersCustomTitle() {
        let withTitle = WebPasskeySummary(id: "a", name: "me@example.com", customTitle: "Work",
                                          relyingParty: "example.com", providerName: "iCloud Keychain")
        XCTAssertEqual(withTitle.displayName, "Work")

        let withoutTitle = WebPasskeySummary(id: "b", name: "me@example.com", customTitle: nil,
                                             relyingParty: "example.com", providerName: "iCloud Keychain")
        XCTAssertEqual(withoutTitle.displayName, "me@example.com")

        // An empty custom title is treated as absent — otherwise the row renders blank.
        let blankTitle = WebPasskeySummary(id: "c", name: "me@example.com", customTitle: "",
                                           relyingParty: "example.com", providerName: "iCloud Keychain")
        XCTAssertEqual(blankTitle.displayName, "me@example.com")
    }
}
