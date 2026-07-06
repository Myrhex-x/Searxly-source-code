//
//  BrowserState+Suggestions.swift
//  Searxly
//
//  Address-bar autocomplete suggestions: local history/bookmarks + remote SearXNG completions.
//  Extracted from SearchCoordinator.swift.
//

import Foundation
import SwiftUI

extension BrowserState {

    // MARK: - Panel lifecycle

    func dismissSuggestionsPanel() {
        suggestionsRefreshTask?.cancel()
        suggestionsRefreshTask = nil
        suggestionBlurDismissTask?.cancel()
        suggestionBlurDismissTask = nil
        suggestionsRequestGeneration &+= 1
        suggestionsPanelSuppressed = true
        suggestions = []
        suggestionsSelectedIndex = 0
        suggestionsIsLoading = false
    }

    /// Drives the suggestions panel off address-bar focus. On focus, refreshes (if there's a query). On
    /// blur, dismisses after a short grace period — long enough for a click that landed on a suggestion
    /// (and thereby blurred the field) to run its action before the panel closes. Cancelled if focus
    /// returns or a selection/submit dismisses sooner.
    func setAddressBarFocused(_ focused: Bool) {
        addressBarFocused = focused
        suggestionBlurDismissTask?.cancel()
        suggestionBlurDismissTask = nil

        if focused {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { scheduleSuggestionsRefresh(userInitiated: false) }
        } else {
            suggestionBlurDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, !self.addressBarFocused else { return }
                self.dismissSuggestionsPanel()
            }
        }
    }

    /// Schedules a debounced refresh (local sites + remote search autocomplete).
    /// - Parameter userInitiated: `true` when the user typed (re-opens panel after dismiss). `false` on focus-only refresh.
    func scheduleSuggestionsRefresh(userInitiated: Bool = true) {
        if userInitiated {
            suggestionsPanelSuppressed = false
        } else if suggestionsPanelSuppressed {
            return
        }

        suggestionsRefreshTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            suggestionsSelectedIndex = 0
            suggestionsIsLoading = false
            return
        }

        // Mark suggestions as pending immediately so Enter submits typed text rather than
        // a stale suggestion that was loaded for a shorter prefix.
        suggestionsIsLoading = true
        suggestionsSelectedIndex = 0

        suggestionsRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await refreshSuggestionsNow()
        }
    }

    func updateSuggestions() {
        scheduleSuggestionsRefresh(userInitiated: true)
    }

    @MainActor
    private func refreshSuggestionsNow() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !suggestionsPanelSuppressed else {
            suggestions = []
            suggestionsSelectedIndex = 0
            suggestionsIsLoading = false
            return
        }

        if !hasHealedCrossedHistoryTitles {
            hasHealedCrossedHistoryTitles = true
            healCrossedHistoryTitles()
        }

        suggestionsRequestGeneration &+= 1
        let generation = suggestionsRequestGeneration
        suggestionsIsLoading = true

        // Speculative SERP prefetch: start the real search once the query settles, so Enter
        // lands on results that are already loading (or loaded). Debounced internally.
        SpeculativeSearchPrefetcher.shared.schedule(query: trimmed, instances: searxInstances)

        let remoteQueries = await SearchAutocompleteService.fetchSearchCompletions(
            query: trimmed,
            instances: searxInstances,
            localeCode: Localization.searchLanguageCode
        )

        guard generation == suggestionsRequestGeneration,
              !Task.isCancelled,
              !suggestionsPanelSuppressed else {
            suggestionsIsLoading = false
            return
        }

        let enabled = PrivacyManager.shared.historyEnabled
        let queryHistoryEnabled = UserDefaults.standard.object(forKey: SearchQueryHistoryStore.enabledKey) as? Bool ?? true
        let pastQueries: [SearchQueryRecord] = queryHistoryEnabled
            ? SearchQueryHistoryStore.shared.matching(trimmed, max: 3)
            : []
        suggestions = SuggestionProvider.mergedSuggestions(
            for: trimmed,
            history: history,
            bookmarks: bookmarks,
            historyEnabled: enabled,
            remoteSearchQueries: remoteQueries,
            pastSearchQueries: pastQueries,
            maxResults: 6
        )
        suggestionsIsLoading = false
        if suggestionsSelectedIndex >= suggestions.count || suggestionsSelectedIndex < 0 {
            suggestionsSelectedIndex = suggestions.isEmpty ? 0 : min(suggestionsSelectedIndex, suggestions.count - 1)
        }
    }

    // MARK: - Submit

    /// Submits the address bar, honoring the highlighted suggestion when the panel is open.
    /// Skips suggestions while loading so a stale result from a previous shorter prefix can't
    /// override the full text the user actually typed.
    func submitAddressBar() {
        if !suggestionsIsLoading,
           !suggestions.isEmpty,
           suggestionsSelectedIndex >= 0,
           suggestionsSelectedIndex < suggestions.count {
            selectSuggestion(suggestions[suggestionsSelectedIndex])
            return
        }
        performSearchOrLoadInWebKit()
    }

    /// Commits the chosen suggestion: updates searchText, hides the panel, and navigates or searches.
    func selectSuggestion(_ suggestion: AddressSuggestion) {
        dismissSuggestionsPanel()

        if let raw = suggestion.url, !raw.isEmpty {
            let withScheme = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: withScheme) {
                searchText = suggestion.title
                loadInWebView(url)
                return
            }
        }

        searchText = suggestion.title
        performSearchOrLoadInWebKit()
    }

    // MARK: - History title healer

    /// Best-effort healer for pre-fix polluted bookmarks (and history storage).
    /// Rewrites titles that claim a famous brand when the host does not belong to that brand.
    /// Called once per launch from refreshSuggestionsNow.
    private func healCrossedHistoryTitles() {
        let brandChecks: [(brand: String, hostTokens: [String])] = [
            ("speedtest", ["speedtest", "ookla"]),
            ("speed test", ["speedtest", "ookla"]),
            ("youtube", ["youtube", "youtu.be"]),
            ("github", ["github"]),
            ("google", ["google"]),
            ("gmail", ["gmail", "google"]),
            ("twitter", ["twitter", "x.com"]),
            ("x.com", ["x.com", "twitter"]),
            ("netflix", ["netflix"]),
            ("reddit", ["reddit"]),
            ("amazon", ["amazon"]),
            ("apple", ["apple"]),
            ("spotify", ["spotify"]),
            ("steam", ["steam", "steampowered"]),
            ("discord", ["discord"]),
            ("twitch", ["twitch"]),
        ]

        var historyChanged = false
        for i in history.indices {
            let item = history[i]
            let t = item.title.lowercased()
            for (brand, tokens) in brandChecks {
                if t.contains(brand) {
                    let h = hostFromURL(item.url)
                    if !tokens.contains(where: { h.contains($0) }) {
                        let oldDate = item.date
                        history[i] = HistoryItem(url: item.url, title: h.isEmpty ? item.url : h, date: oldDate)
                        historyChanged = true
                        break
                    }
                }
            }
        }
        if historyChanged { Persistence.saveHistory(history) }

        var bookmarksChanged = false
        for i in bookmarks.indices {
            let item = bookmarks[i]
            let t = item.title.lowercased()
            for (brand, tokens) in brandChecks {
                if t.contains(brand) {
                    let h = hostFromURL(item.url)
                    if !tokens.contains(where: { h.contains($0) }) {
                        bookmarks[i] = BookmarkItem(url: item.url, title: h.isEmpty ? item.url : h, dateAdded: item.dateAdded, note: item.note)
                        bookmarksChanged = true
                        break
                    }
                }
            }
        }
        if bookmarksChanged { Persistence.saveBookmarks(bookmarks) }
    }

    private func hostFromURL(_ urlString: String) -> String {
        guard let u = URL(string: urlString), let h = u.host?.lowercased() else { return "" }
        return h.replacingOccurrences(of: "www.", with: "")
    }
}
