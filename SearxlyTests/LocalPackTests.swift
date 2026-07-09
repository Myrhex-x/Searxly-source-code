//
//  LocalPackTests.swift
//  SearxlyTests
//
//  Guards the local-pack query detector (place intent → category + city) against false positives that
//  would hijack ordinary searches, and pins the opening-hours evaluator's open/closed logic.
//

import XCTest
@testable import Searxly

final class LocalPackQueryDetectorTests: XCTestCase {

    // MARK: - Positive detection

    func testDetectsCategoryPlusCity() {
        let q = LocalPackQueryDetector.detect("pharmacie perpignan")
        XCTAssertEqual(q?.category, "pharmacy")
        XCTAssertEqual(q?.area, "perpignan")

        XCTAssertEqual(LocalPackQueryDetector.detect("restaurant lyon")?.category, "restaurant")
        XCTAssertEqual(LocalPackQueryDetector.detect("hotel nice")?.category, "hotel")
        XCTAssertEqual(LocalPackQueryDetector.detect("boulangerie bordeaux")?.category, "bakery")
        XCTAssertEqual(LocalPackQueryDetector.detect("gym london")?.area, "london")
    }

    func testAccentsAndMultiWordTriggers() {
        // Accent-folded FR trigger.
        XCTAssertEqual(LocalPackQueryDetector.detect("médecin toulouse")?.category, "doctor")
        // Multi-word trigger consumes both tokens; the rest is the city.
        let coffee = LocalPackQueryDetector.detect("coffee shop paris")
        XCTAssertEqual(coffee?.category, "cafe")
        XCTAssertEqual(coffee?.area, "paris")
    }

    func testConnectivesAreDropped() {
        XCTAssertEqual(LocalPackQueryDetector.detect("restaurant à lyon")?.area, "lyon")
        XCTAssertEqual(LocalPackQueryDetector.detect("pharmacy in london")?.area, "london")
    }

    // MARK: - False-positive avoidance (must NOT hijack ordinary searches)

    func testNonPlaceQueriesReturnNil() {
        XCTAssertNil(LocalPackQueryDetector.detect("elon musk"))
        XCTAssertNil(LocalPackQueryDetector.detect("bitcoin price"))
        XCTAssertNil(LocalPackQueryDetector.detect("how to cook rice"))
        XCTAssertNil(LocalPackQueryDetector.detect("taylor swift"))
        // "bank" is an ambiguous common word → only fires when it LEADS, so "world bank" stays a web search.
        XCTAssertNil(LocalPackQueryDetector.detect("world bank"))
    }

    func testBrandsResolveWithNameFilter() {
        let mcd = LocalPackQueryDetector.detect("mcdonalds paris")
        XCTAssertEqual(mcd?.category, "fast_food")
        XCTAssertEqual(mcd?.area, "paris")
        XCTAssertEqual(mcd?.name, "mcdonald")

        XCTAssertEqual(LocalPackQueryDetector.detect("starbucks lyon")?.category, "cafe")
        XCTAssertEqual(LocalPackQueryDetector.detect("carrefour nice")?.category, "supermarket")
        // Brand can trail the city too.
        XCTAssertEqual(LocalPackQueryDetector.detect("paris mcdonalds")?.area, "paris")
    }

    func testCategoryAnywhereDropsLeadingAdjective() {
        let q = LocalPackQueryDetector.detect("meilleur restaurant paris")
        XCTAssertEqual(q?.category, "restaurant")
        XCTAssertEqual(q?.area, "paris")        // "meilleur" dropped; the city trails the category
        // A strict-leading category still works when it actually leads.
        XCTAssertEqual(LocalPackQueryDetector.detect("bank paris")?.category, "bank")
    }

    func testBarePlaceStrongTriggerUsesLocation() {
        let mcd = LocalPackQueryDetector.detect("mcdonalds")
        XCTAssertEqual(mcd?.useCurrentLocation, true)
        XCTAssertNil(mcd?.area)
        XCTAssertEqual(mcd?.category, "fast_food")

        XCTAssertEqual(LocalPackQueryDetector.detect("restaurant")?.useCurrentLocation, true)
        XCTAssertEqual(LocalPackQueryDetector.detect("pharmacie")?.useCurrentLocation, true)
    }

    func testNearMePhrasingUsesLocation() {
        let q = LocalPackQueryDetector.detect("restaurant near me")
        XCTAssertEqual(q?.useCurrentLocation, true)
        XCTAssertNil(q?.area)
        XCTAssertEqual(LocalPackQueryDetector.detect("pharmacie autour de moi")?.useCurrentLocation, true)
    }

    func testAmbiguousBareWordsDoNotUseLocation() {
        // Strict-leading common words never trigger the location path on their own.
        XCTAssertNil(LocalPackQueryDetector.detect("bank"))
        XCTAssertNil(LocalPackQueryDetector.detect("gym"))
        XCTAssertNil(LocalPackQueryDetector.detect("bar"))
    }

    func testExplicitCityDoesNotUseLocation() {
        XCTAssertEqual(LocalPackQueryDetector.detect("pharmacie perpignan")?.useCurrentLocation, false)
        XCTAssertEqual(LocalPackQueryDetector.detect("mcdonalds paris")?.useCurrentLocation, false)
    }

    func testURLInputReturnsNil() {
        XCTAssertNil(LocalPackQueryDetector.detect("restaurant.com"))
        XCTAssertNil(LocalPackQueryDetector.detect("https://restaurant/lyon"))
    }
}

final class OpeningHoursEvaluatorTests: XCTestCase {

    // 2026-01-05 is a Monday; 01-03 Saturday; 01-04 Sunday.
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
    }

    func testOpenAndClosedWithinWeekday() {
        let spec = "Mo-Fr 09:00-18:00"
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(spec, now: date(day: 5, hour: 10)), .open(closesAt: "18:00"))
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(spec, now: date(day: 5, hour: 8)), .closed(opensAt: "09:00"))
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(spec, now: date(day: 5, hour: 19)), .closed(opensAt: nil))
    }

    func testSplitDayReopens() {
        let spec = "Mo-Fr 09:00-12:00,14:00-19:00"
        // Lunch gap → closed, reopening at 14:00.
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(spec, now: date(day: 5, hour: 13)), .closed(opensAt: "14:00"))
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(spec, now: date(day: 5, hour: 10)), .open(closesAt: "12:00"))
    }

    func testWeekdayScoping() {
        // Weekday-only spec → closed on Saturday.
        XCTAssertEqual(OpeningHoursEvaluator.evaluate("Mo-Fr 09:00-18:00", now: date(day: 3, hour: 10)), .closed(opensAt: nil))
        // Saturday rule applies on Saturday.
        XCTAssertEqual(OpeningHoursEvaluator.evaluate("Sa 09:00-12:00", now: date(day: 3, hour: 10)), .open(closesAt: "12:00"))
    }

    func testAlwaysOpenAndUnparseable() {
        XCTAssertEqual(OpeningHoursEvaluator.evaluate("24/7"), .open(closesAt: nil))
        XCTAssertEqual(OpeningHoursEvaluator.evaluate(""), .unknown)
        XCTAssertEqual(OpeningHoursEvaluator.evaluate("sunrise-sunset"), .unknown)
    }
}
