//
//  AIOverviewModel.swift
//  SearxlyiOS
//
//  Owns the SERP AI Overview's generation state (phase, streamed answer, follow-ups) on the STABLE
//  per-tab BrowserModel — NOT in the card's @State. That's the whole point: the search results live in
//  a `List`, which recycles/rebuilds rows as async content (news, images, favicons) loads. When the
//  state lived in the card, every reflow tore the card down, reset it to "Generate", and cancelled the
//  in-flight generation — so tapping Generate appeared to do nothing. Here the generation survives view
//  recycling: a rebuilt card just re-reads this model and shows the streaming/finished state.
//

import Foundation
import Observation

@MainActor
@Observable
final class AIOverviewModel {
    enum Phase: Equatable { case idle, streaming, done, failed }

    private(set) var phase: Phase = .idle
    private(set) var answer = ""
    private(set) var followUps: [String] = []
    private(set) var failureMessage = ""
    private(set) var sourceCount = 0

    /// The query the current state belongs to, so a genuine new search resets while the same query
    /// re-appearing (row recycling / scope flips back to All) keeps the in-flight or finished state.
    private var query = ""
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    /// Point the model at the card's current query. A no-op when the query is unchanged — which is
    /// exactly what makes the generation survive the card being rebuilt.
    func sync(query: String) {
        guard query != self.query else { return }
        self.query = query
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        if let hit = SearchIntelligence.cached(for: query) {
            answer = hit.text
            followUps = hit.followUps
            sourceCount = hit.sourceCount
            phase = .done
        } else {
            answer = ""
            followUps = []
            failureMessage = ""
            sourceCount = 0
            phase = .idle
        }
    }

    /// Kick off (or retry) generation for the synced query. Ignored if already streaming.
    func generate(results: [SearXNGResult], suggestions: [String], isPrivate: Bool) {
        guard phase != .streaming else { return }
        task?.cancel()
        answer = ""
        followUps = []
        failureMessage = ""
        phase = .streaming
        sourceCount = min(results.count, 8)
        let query = self.query
        startWatchdog()
        task = Task { [weak self] in
            // Related searches load concurrently with the answer.
            async let related = Self.loadFollowUps(query: query, suggestions: suggestions, isPrivate: isPrivate)
            do {
                var streamed = ""
                for try await snapshot in SearchIntelligence.overview(query: query, results: results) {
                    guard !Task.isCancelled else { return }
                    streamed = snapshot
                    self?.answer = snapshot
                }
                let ups = await related
                guard !Task.isCancelled, let self else { return }
                self.followUps = ups
                if streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.failureMessage = L("The overview came back empty. Tap to try again.")
                    self.phase = .failed
                } else {
                    _ = SearchIntelligence.store(answer: streamed, followUps: ups,
                                                 query: query, sourceCount: self.sourceCount)
                    self.phase = .done
                }
            } catch {
                let ups = await related
                guard !Task.isCancelled, let self else { return }
                // Never hide a generation failure behind loaded follow-ups: an empty answer always
                // surfaces the real reason with tap-to-retry (a blank "done" card is what "the AI
                // doesn't work" looks like).
                self.followUps = ups
                if self.answer.isEmpty {
                    self.failureMessage = PageIntelligence.friendlyError(error)
                    self.phase = .failed
                } else {
                    self.phase = .done
                }
            }
        }
    }

    /// Turns an endless spinner into a tap-to-retry failure if the model produces nothing at all within
    /// the window. No-ops once any token arrives. Never cancels the model task (mid-inference cancel is
    /// a documented crash risk) — it only flips the UI; a late answer simply replaces this state.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.phase == .streaming, self.answer.isEmpty else { return }
            self.failureMessage = L("The on-device model didn't respond. Tap to try again.")
            self.phase = .failed
        }
    }

    /// Related searches: the instance's own suggestions when present, else the autocompleter (skipped
    /// in private tabs to keep their footprint minimal).
    private static func loadFollowUps(query: String, suggestions: [String], isPrivate: Bool) async -> [String] {
        let instanceSuggestions = suggestions.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        if !instanceSuggestions.isEmpty { return Array(instanceSuggestions.prefix(4)) }
        guard !isPrivate else { return [] }
        return Array(await SearchIntelligence.relatedSearches(for: query).prefix(4))
    }
}
