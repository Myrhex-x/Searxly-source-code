//
//  SpeculativeSearchPrefetcher.swift
//  Searxly
//
//  Starts the SearXNG search while the user is still typing, so pressing Enter feels instant:
//  the SERP consumes the already-running (or finished) request instead of starting from zero.
//
//  Guardrails (why this doesn't hammer the engines or leak anything):
//  - Fires only after the query has SETTLED for a beat (`settleDelay`) — fast typists never
//    trigger it mid-word; superseded schedules are cancelled before any network happens.
//  - One speculative slot: a new query cancels the previous in-flight task.
//  - Talks only to the user's own private SearXNG instances through the exact same
//    `searchWithFallback` call a real search uses (same PrivacyGate rules, nothing recorded
//    in history — history is written on submit, not here).
//  - Skips URL-ish input and bang shortcuts (those never become native searches).
//

import Foundation

@MainActor
final class SpeculativeSearchPrefetcher {
    static let shared = SpeculativeSearchPrefetcher()

    /// How long the typed query must sit unchanged before we speculate. Long enough that
    /// mid-typing pauses rarely fire (each speculative search fans out to the real engines);
    /// short enough that "type, glance, Enter" still wins the race.
    private let settleDelay: Duration = .milliseconds(450)
    /// A speculative result older than this is stale — engines and safesearch settings move on.
    private let freshness: TimeInterval = 60

    private struct Entry {
        let key: String
        let startedAt: Date
        let task: Task<([SearXNGResult], String?), Error>
    }

    private var pendingSchedule: Task<Void, Never>?
    private var entry: Entry?

    private init() {}

    private func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Called on every suggestions refresh (i.e. every keystroke, cheaply). Debounces internally.
    func schedule(query: String, instances: [SearXNGInstance]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalize(trimmed)

        guard trimmed.count >= 3,
              !trimmed.hasPrefix("!"),
              !instances.isEmpty,
              !SearchAutocompleteService.looksLikeURLInput(trimmed)
        else {
            pendingSchedule?.cancel()
            pendingSchedule = nil
            return
        }

        // Already speculating on exactly this query (pending or in flight) — keep the head start.
        if entry?.key == key { return }

        pendingSchedule?.cancel()
        pendingSchedule = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            guard !Task.isCancelled else { return }
            self.begin(trimmed: trimmed, key: key, instances: instances)
        }
    }

    private func begin(trimmed: String, key: String, instances: [SearXNGInstance]) {
        entry?.task.cancel()

        let language = Localization.searchLanguageCode
        let options = SearchContentSafety.shared.searchOptions(pageNo: 1)
        let task = Task<([SearXNGResult], String?), Error> {
            let (results, usedURL) = try await SearXNGService.shared.searchWithFallback(
                query: trimmed,
                categories: nil,
                instances: instances,
                language: language,
                options: options
            )
            return (results, usedURL)
        }
        entry = Entry(key: key, startedAt: Date(), task: task)
    }

    /// Hands over the speculative request for a submitted query (single use). Returns nil when
    /// there's no fresh matching speculation — the caller then searches normally.
    func consume(query: String) -> Task<([SearXNGResult], String?), Error>? {
        pendingSchedule?.cancel()
        pendingSchedule = nil
        guard let current = entry,
              current.key == normalize(query),
              Date().timeIntervalSince(current.startedAt) < freshness
        else { return nil }
        entry = nil
        return current.task
    }

    /// Drops any pending or in-flight speculation (e.g. the address bar was cleared).
    func invalidate() {
        pendingSchedule?.cancel()
        pendingSchedule = nil
        entry?.task.cancel()
        entry = nil
    }
}
