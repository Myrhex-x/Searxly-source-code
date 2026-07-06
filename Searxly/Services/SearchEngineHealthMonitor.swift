//
//  SearchEngineHealthMonitor.swift
//  Searxly
//
//  Watches native-search outcomes from the bundled local SearXNG and raises a visible
//  "engines may be outdated" signal when queries persistently return nothing.
//
//  Why: the bundled runtime's engine scrapers rot as upstream sites change their markup
//  (that — not IP blocking — caused the 2026-06 "few results / no Google" bug), and the
//  failure is silent: process healthy, HTTP 200, zero results. This monitor is the
//  tripwire for that failure mode. See BUNDLED-RUNTIMES.md for the update cadence.
//

import Foundation
import os

@MainActor
@Observable
final class SearchEngineHealthMonitor {
    static let shared = SearchEngineHealthMonitor()

    /// Bundled runtime older than this many days is flagged as stale in Settings.
    private nonisolated static let runtimeStaleAfterDays = 180

    /// Consecutive zero-result local searches before we call the engines degraded.
    private nonisolated static let consecutiveEmptyThreshold = 3

    private var consecutiveEmptyLocalSearches = 0
    private var toastShownThisRun = false

    /// True while local searches persistently return nothing (resets on the first healthy search).
    private(set) var enginesLookDegraded = false

    private init() {}

    // MARK: - Recording

    /// Records the outcome of a completed fresh search. Only zero-result *successes* against the
    /// local instance count toward degradation — network errors have their own error surface, and
    /// remote instances aren't the bundled runtime's problem.
    func recordSearchOutcome(resultCount: Int, instanceURL: String?) {
        guard isLocalInstance(instanceURL) else { return }

        if resultCount > 0 {
            consecutiveEmptyLocalSearches = 0
            enginesLookDegraded = false
            return
        }

        consecutiveEmptyLocalSearches += 1
        guard consecutiveEmptyLocalSearches >= Self.consecutiveEmptyThreshold else { return }
        let firstTrip = !enginesLookDegraded
        enginesLookDegraded = true
        Log.search.warning("SearchEngineHealthMonitor: \(self.consecutiveEmptyLocalSearches) consecutive zero-result local searches — engines look degraded (runtime \(SearxngRuntimeConfig.bundledVersion, privacy: .public))")

        if firstTrip && !toastShownThisRun {
            toastShownThisRun = true
            NotificationManager.shared.showInApp(
                title: "Search engines may be outdated",
                body: bundledRuntimeIsStale
                    ? "Local searches keep returning nothing, and the bundled search runtime is \(bundledRuntimeAgeDescription) old. Check for a Searxly update."
                    : "Local searches keep returning nothing. Check your connection, or check for a Searxly update.",
                source: "Search",
                iconSystemName: "exclamationmark.magnifyingglass"
            )
        }
    }

    private func isLocalInstance(_ urlString: String?) -> Bool {
        guard let urlString, let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - Bundled runtime staleness

    /// The build date encoded in SearxngRuntimeConfig.bundledVersion ("2026.6.23-e371371").
    nonisolated static let bundledRuntimeDate: Date? = {
        let datePart = SearxngRuntimeConfig.bundledVersion.split(separator: "-").first ?? ""
        let parts = datePart.split(separator: ".").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        return Calendar(identifier: .gregorian).date(from: comps)
    }()

    nonisolated var bundledRuntimeAgeDays: Int? {
        guard let date = Self.bundledRuntimeDate else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    /// True when the bundled engines are old enough that scraper rot is likely, regardless of
    /// whether searches have started failing yet.
    nonisolated var bundledRuntimeIsStale: Bool {
        (bundledRuntimeAgeDays ?? 0) >= Self.runtimeStaleAfterDays
    }

    nonisolated var bundledRuntimeAgeDescription: String {
        guard let days = bundledRuntimeAgeDays, days > 0 else { return "0 days" }
        if days >= 60 { return "\(days / 30) months" }
        return "\(days) days"
    }
}
