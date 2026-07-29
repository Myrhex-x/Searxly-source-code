//
//  EngineHardeningProbeTests.swift
//  SearxlyTests
//
//  Pins the probe's MECHANICS: it must build a web view, load the blank page, run the probe script,
//  and come back with real observations. The hardened VALUES aren't asserted here — the test host
//  runs the base edition with whatever privacy mode the host app has, so expectations would flake;
//  PrivacySelfTest owns the edition-aware verdicts. What matters is that a probe failure returns
//  nil (surfaced as "couldn't verify") instead of fabricated observations.
//

import XCTest
import WebKit
@testable import Searxly

final class EngineHardeningProbeTests: XCTestCase {

    @MainActor
    func testProbeReturnsRealObservations() async {
        let obs = await EngineHardeningProbe.observe()
        guard let obs else {
            XCTFail("probe returned nil — the scratch web view never loaded or the script failed")
            return
        }
        // Fields must carry observed values, not decoding fallbacks.
        XCTAssertFalse(obs.language.isEmpty, "navigator.language should always read as something")
        XCTAssertNotEqual(obs.timezoneOffset, Int.min, "timezone offset should decode from the page")
        // A UTC offset is 0; any real offset is within ±14h. Anything else means the bridge broke.
        XCTAssertLessThanOrEqual(abs(obs.timezoneOffset), 14 * 60)
    }
}
