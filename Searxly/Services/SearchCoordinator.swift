//
//  SearchCoordinator.swift
//  Searxly
//
//  Core search pipeline, knowledge panel, and Local AI search-adjacent hooks.
//  Suggestions → BrowserState+Suggestions.swift
//  Tab/site actions → BrowserState+SiteNavigation.swift
//

import Foundation
import os
import SwiftUI
import WebKit

extension BrowserState {

    // MARK: - Entry point

    func performSearchOrLoadInWebKit() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        dismissSuggestionsPanel()

        // Bang shortcuts: !g query → Google, !yt query → YouTube, etc.
        if let bangURL = Self.resolveBang(trimmed) {
            loadInWebView(bangURL)
            clearNativeSearch()
            return
        }

        if let url = smartURL(from: trimmed) {
            // .onion is only reachable over Tor. loadInWebView routes it into a dedicated onion tab
            // (unless the current tab is already an onion tab, where it navigates in place).
            loadInWebView(url)
            clearNativeSearch()
        } else {
            lastSearchQuery = trimmed
            currentSearchCategory = nil

            let lower = trimmed.lowercased()
            if !LocalIntelligenceManager.shared.toolsEnabled && LocalIntelligenceManager.shared.canUseFeatures &&
               (lower.hasPrefix("search") || lower.hasPrefix("find ") || lower.contains("?") ||
                lower.hasPrefix("what ") || lower.hasPrefix("how ") || lower.hasPrefix("who ")) {
                showEnableAIToolsPrompt = true
            }

            if searxInstances.isEmpty {
                searchErrorMessage = "No private SearXNG instance configured. Add one in Settings → SearXNG Instances to enable search. (Direct URLs still work.)"
                searchResults = []
                isLoadingSearch = false
                showingWebContent = false
                return
            }

            Task { @MainActor in
                await performFreshSearch(query: trimmed, category: currentSearchCategory)
            }
        }
    }

    // MARK: - State reset

    func clearNativeSearch() {
        cancelKnowledgePanelTask()
        knowledgePanelState = .hidden
        searchResults = []
        searchErrorMessage = nil
        lastSearchQuery = ""
        lastEffectiveSearchQuery = ""
        currentSearchCategory = nil
        isLoadingSearch = false
        searchPageNo = 1
        isLoadingMoreResults = false
        canLoadMoreResults = true
        consecutiveEmptyLoadMorePages = 0
        showEnableAIToolsPrompt = false
        highlightedResultURL = nil
        lastSearchInstanceURL = nil
    }

    func setKnowledgePanelEnabled(_ enabled: Bool) {
        guard enabled != knowledgePanelEnabled else { return }
        knowledgePanelEnabled = enabled
        Persistence.setKnowledgePanelEnabled(enabled)
        if !enabled {
            cancelKnowledgePanelTask()
            knowledgePanelState = .hidden
        } else if !searchResults.isEmpty {
            refreshKnowledgePanel()
        }
    }

    func clearSearchHistory() {
        lastSearchQuery = ""
        searchErrorMessage = nil
    }

    // MARK: - Category + refresh

    func selectSearchCategory(_ category: String?) {
        guard !lastSearchQuery.isEmpty else { return }
        let priorCategory = currentSearchCategory
        currentSearchCategory = category
        Task { @MainActor in
            let preserve = Self.sameResultsLayout(priorCategory, category)
            await performFreshSearch(
                query: lastSearchQuery,
                category: category,
                preserveResultsWhileLoading: preserve,
                recordInHistory: false
            )
        }
    }

    func refreshSearchAfterContentSafetyChange() {
        guard !lastSearchQuery.isEmpty, !showingWebContent else { return }
        Task { @MainActor in
            await performFreshSearch(
                query: lastSearchQuery,
                category: currentSearchCategory,
                preserveResultsWhileLoading: false,
                recordInHistory: false
            )
        }
    }

    // MARK: - Search Bangs

    /// Maps DuckDuckGo-style bangs to their search URL templates.
    /// `%s` is replaced with the URL-encoded query.
    static let bangs: [String: String] = [
        "g":    "https://www.google.com/search?q=%s",
        "yt":   "https://www.youtube.com/results?search_query=%s",
        "gh":   "https://github.com/search?q=%s",
        "r":    "https://www.reddit.com/search/?q=%s",
        "so":   "https://stackoverflow.com/search?q=%s",
        "a":    "https://www.amazon.com/s?k=%s",
        "w":    "https://en.wikipedia.org/wiki/Special:Search?search=%s",
        "img":  "https://www.google.com/search?tbm=isch&q=%s",
        "maps": "https://www.google.com/maps/search/%s",
        "tw":   "https://twitter.com/search?q=%s",
        "npm":  "https://www.npmjs.com/search?q=%s",
        "pypi": "https://pypi.org/search/?q=%s",
        "wb":   "https://web.archive.org/web/*/%s",
        "ddg":  "https://duckduckgo.com/?q=%s",
        "b":    "https://www.bing.com/search?q=%s",
    ]

    /// If `query` starts with `!bang`, returns the resolved URL; otherwise nil.
    static func resolveBang(_ query: String) -> URL? {
        guard query.hasPrefix("!") else { return nil }
        let parts = query.dropFirst().split(separator: " ", maxSplits: 1)
        guard parts.count >= 1 else { return nil }
        let bang = parts[0].lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard let template = bangs[bang] else { return nil }
        let encoded = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rest
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    private static func sameResultsLayout(_ a: String?, _ b: String?) -> Bool {
        func family(_ c: String?) -> String {
            switch c {
            case "images", "videos": return "media"
            case "news": return "news"
            default: return "web"
            }
        }
        return family(a) == family(b)
    }

    // MARK: - Pagination

    /// Give up infinite scroll only after this many *consecutive* pages add nothing new — a single
    /// empty page is usually a transient engine block (CAPTCHA/429), not the true end of results.
    static let maxConsecutiveEmptyLoadMorePages = 3
    /// Hard ceiling so a perpetually-duplicate engine can't spin the loader forever.
    static let maxSearchPage = 15

    func loadMoreSearchResults() {
        guard !lastEffectiveSearchQuery.isEmpty,
              canLoadMoreResults,
              !isLoadingMoreResults,
              !isLoadingSearch else { return }

        Task { @MainActor in
            isLoadingMoreResults = true
            let nextPage = searchPageNo + 1
            do {
                let (raw, usedURL) = try await SearXNGService.shared.searchWithFallback(
                    query: lastEffectiveSearchQuery,
                    categories: currentSearchCategory,
                    instances: searxInstances,
                    language: Localization.searchLanguageCode,
                    options: SearchContentSafety.shared.searchOptions(pageNo: nextPage)
                )
                lastSearchInstanceURL = usedURL
                let newCount = SearchResultProcessor.countNewItems(
                    existing: searchResults,
                    incoming: raw,
                    category: currentSearchCategory,
                    query: lastEffectiveSearchQuery
                )
                // Always advance the page cursor: a dry page (all duplicates or an engine
                // momentarily blocked) must not permanently freeze scroll — the next page often
                // recovers. We stop only after several dry pages in a row, or at the page ceiling.
                searchPageNo = nextPage
                if newCount > 0 {
                    searchResults = SearchResultProcessor.process(
                        raw: raw,
                        existing: searchResults,
                        query: lastSearchQuery,
                        category: currentSearchCategory,
                        append: true
                    )
                    consecutiveEmptyLoadMorePages = 0
                } else {
                    consecutiveEmptyLoadMorePages += 1
                }
                canLoadMoreResults =
                    consecutiveEmptyLoadMorePages < Self.maxConsecutiveEmptyLoadMorePages
                    && nextPage < Self.maxSearchPage
            } catch {
                // A transient network/parse error shouldn't kill scroll outright; count it toward
                // the dry-page budget and don't advance the cursor so the same page can be retried.
                consecutiveEmptyLoadMorePages += 1
                canLoadMoreResults = consecutiveEmptyLoadMorePages < Self.maxConsecutiveEmptyLoadMorePages
                Log.search.error("SearXNG load-more error: \(error)")
            }
            isLoadingMoreResults = false
        }
    }

    // MARK: - Search pipeline

    private func performFreshSearch(
        query: String,
        category: String?,
        preserveResultsWhileLoading: Bool = false,
        recordInHistory: Bool = true
    ) async {
        if recordInHistory { pushCurrentBrowseStateToBackStack() }
        if searxInstances.isEmpty {
            searchErrorMessage = "No private SearXNG instance configured. Add one in Settings → SearXNG Instances to enable search. (Direct URLs still work.)"
            searchResults = []
            isLoadingSearch = false
            showingWebContent = false
            return
        }

        isLoadingSearch = true
        searchErrorMessage = nil
        if !preserveResultsWhileLoading { searchResults = [] }
        showingWebContent = false
        searchPageNo = 1
        canLoadMoreResults = true
        isLoadingMoreResults = false
        consecutiveEmptyLoadMorePages = 0

        let effectiveQuery = await maybeRewriteQuery(query)
        lastEffectiveSearchQuery = effectiveQuery

        do {
            let (results, usedURL) = try await SearXNGService.shared.searchWithFallback(
                query: effectiveQuery,
                categories: category,
                instances: searxInstances,
                language: Localization.searchLanguageCode,
                options: SearchContentSafety.shared.searchOptions(pageNo: 1)
            )
            lastSearchInstanceURL = usedURL
            searchResults = SearchResultProcessor.process(
                raw: results,
                query: query,
                category: category,
                append: false
            )
            if searchResults.isEmpty {
                searchErrorMessage = category == nil
                    ? "No results found across all your SearXNG instances."
                    : "No results in this category."
            } else {
                // Persist the query for future search history suggestions.
                let queryHistoryEnabled = UserDefaults.standard.object(forKey: SearchQueryHistoryStore.enabledKey) as? Bool ?? true
                if queryHistoryEnabled {
                    SearchQueryHistoryStore.shared.record(query)
                }
            }
        } catch {
            if !preserveResultsWhileLoading { searchResults = [] }
            searchErrorMessage = error is SearXNGError
                ? "No working private SearXNG instance reachable. Check your instance in Settings, or start the local one."
                : "Search error: \(error.localizedDescription)"
            Log.search.error("SearXNG fetch error: \(error)")
        }
        isLoadingSearch = false
        refreshKnowledgePanel()
    }

    // MARK: - Knowledge panel

    func cancelKnowledgePanelTask() {
        knowledgePanelTask?.cancel()
        knowledgePanelTask = nil
    }

    func refreshKnowledgePanel() {
        cancelKnowledgePanelTask()

        guard knowledgePanelEnabled,
              !lastSearchQuery.isEmpty,
              !searchResults.isEmpty,
              currentSearchCategory != "images",
              currentSearchCategory != "videos" else {
            knowledgePanelState = .hidden
            return
        }

        guard KnowledgeQueryDetector.classify(lastSearchQuery) != .none else {
            knowledgePanelState = .hidden
            return
        }

        let query = lastSearchQuery
        knowledgePanelState = .loading(query: query)

        knowledgePanelTask = Task {
            let content = await KnowledgePanelService.resolve(query: query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                knowledgePanelState = content != nil ? .ready(content!) : .hidden
            }
        }
    }

    // MARK: - URL detection (used here and in BrowserState+SiteNavigation)

    func smartURL(from text: String) -> URL? {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.contains("://") { return URL(string: input) }
        if input.contains(".") && !input.contains(" ") {
            if !input.hasPrefix("http") {
                // Onion services are HTTP-only by convention — Tor encrypts + authenticates traffic
                // via the .onion address itself, and most onions don't serve TLS. Forcing https://
                // hangs them (the TLS handshake never completes), so default bare .onion hosts to http://.
                let hostPart = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
                let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
                input = (bareHost.lowercased().hasSuffix(".onion") ? "http://" : "https://") + input
            }
            return URL(string: input)
        }
        if input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") || input.hasPrefix("::1") {
            if !input.hasPrefix("http") { input = "http://" + input }
            return URL(string: input)
        }
        return nil
    }

    // MARK: - Local AI hooks

    func maybeRewriteQuery(_ raw: String) async -> String {
        await LocalIntelligenceManager.shared.rewriteIfEnabled(original: raw)
    }

    func highlightResult(url: String) {
        highlightedResultURL = url
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1450))
            if highlightedResultURL == url { highlightedResultURL = nil }
        }
    }

    func openLocalAIChat() {
        LocalIntelligenceManager.shared.startOrContinueChat()
        LocalIntelligenceManager.shared.warmUpIfNeeded()

        if LocalIntelligenceManager.shared.preferences.masterEnabled &&
           LocalIntelligenceManager.shared.preferences.ragEnabled {
            LocalIntelligenceManager.shared.rebuildRAGIndex(history: history, bookmarks: bookmarks)
        }

        showingLocalAIChat = true
    }

    func clearAIState() {
        showingLocalAIChat = false
        LocalIntelligenceManager.shared.clearCurrentChatTranscript()
    }

    func searchMyHistory(query: String) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Array(history.sorted { $0.date > $1.date }.prefix(12)) }
        let q = trimmed.lowercased()
        let filtered = history.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        return Array(filtered.sorted { $0.date > $1.date }.prefix(15))
    }
}
