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
            PrivacyDisclosures.showOnce(
                .bangShortcuts,
                title: "Bang searches leave Searxly",
                body: "This query goes directly to \(bangURL.host ?? "the third-party site") — bang shortcuts (!g, !yt, …) bypass your private SearXNG."
            )
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
            // A brand-new query starts from clean news defaults (don't carry a stale time filter/sort).
            newsTimeRange = nil
            newsSortByRecency = false

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
        SpeculativeSearchPrefetcher.shared.invalidate()
        cancelKnowledgePanelTask()
        knowledgePanelState = .hidden
        cancelLocalPackTask()
        localPackDetected = nil
        localPackState = .hidden
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
        highlightedResultURL = nil
        lastSearchInstanceURL = nil
        newsTimeRange = nil
        newsSortByRecency = false
        newsLastRefreshed = nil
        cancelAllTabNews()
        stopNewsAutoRefresh()
        pendingNewsStories = []
    }

    // MARK: - News controls

    /// Runs a news search for `query` and lands on the News tab — the home "See all" / topic action.
    func runNewsSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !searxInstances.isEmpty else { return }
        dismissSuggestionsPanel()
        searchText = trimmed
        lastSearchQuery = trimmed
        currentSearchCategory = "news"
        newsTimeRange = nil
        newsSortByRecency = false
        Task { @MainActor in
            await performFreshSearch(query: trimmed, category: "news")
        }
    }

    /// Applies a news time-range filter (nil / "day" / "week" / "month" / "year") and refetches.
    /// No-op when the value is unchanged so tapping the active pill doesn't thrash the network.
    func setNewsTimeRange(_ range: String?) {
        guard currentSearchCategory == "news", !lastSearchQuery.isEmpty else { return }
        guard newsTimeRange != range else { return }
        newsTimeRange = range
        Task { @MainActor in
            await performFreshSearch(
                query: lastSearchQuery,
                category: "news",
                preserveResultsWhileLoading: true,
                recordInHistory: false
            )
        }
    }

    /// Toggles Latest-first vs. Top. A pure view-layer sort (see SearchResultsView) — instant, no refetch.
    func setNewsSortByRecency(_ recency: Bool) {
        guard newsSortByRecency != recency else { return }
        newsSortByRecency = recency
        pendingNewsStories = []
        syncNewsAutoRefresh()
    }

    /// Re-pulls the freshest news for the current query (the "refresh / new stories" affordance).
    func refreshNews() {
        guard currentSearchCategory == "news", !lastSearchQuery.isEmpty, !isLoadingSearch else { return }
        Task { @MainActor in
            await performFreshSearch(
                query: lastSearchQuery,
                category: "news",
                preserveResultsWhileLoading: true,
                recordInHistory: false
            )
        }
    }

    // MARK: - All-tab "Top stories" module

    /// Resolves fresh news for the current All query in the background so a Google-style "Top stories"
    /// module can appear among the general results. Goes through the same privacy-gated SearXNGService,
    /// so the egress law is unchanged. Silent on failure — the module simply won't show.
    func beginAllTabNewsResolution(query: String) {
        cancelAllTabNews()
        guard !query.isEmpty, !searxInstances.isEmpty else { return }
        let q = query
        allTabNewsTask = Task { @MainActor in
            let fetched = try? await SearXNGService.shared.searchWithFallback(
                query: q,
                categories: "news",
                instances: searxInstances,
                language: Localization.searchLanguageCode,
                options: SearchContentSafety.shared.searchOptions(pageNo: 1)
            )
            guard !Task.isCancelled,
                  self.currentSearchCategory == nil,
                  self.lastEffectiveSearchQuery == q,
                  let raw = fetched?.results, !raw.isEmpty else { return }
            self.allTabNewsResults = SearchResultProcessor.process(
                raw: raw, query: q, category: "news", append: false
            )
        }
    }

    func cancelAllTabNews() {
        allTabNewsTask?.cancel()
        allTabNewsTask = nil
        allTabNewsResults = []
    }

    // MARK: - Live news auto-refresh

    /// How often the news tab polls for new stories while in Latest mode.
    static let newsAutoRefreshInterval: TimeInterval = 60

    /// Starts or stops the background poll to match the current state — it runs only while the news tab
    /// is in Latest mode with results on screen. Call after any state change that could flip that.
    func syncNewsAutoRefresh() {
        let shouldRun = currentSearchCategory == "news"
            && newsSortByRecency
            && !searchResults.isEmpty
            && !searxInstances.isEmpty
        if shouldRun {
            if newsAutoRefreshTask == nil { startNewsAutoRefreshLoop() }
        } else {
            stopNewsAutoRefresh()
        }
    }

    func stopNewsAutoRefresh() {
        newsAutoRefreshTask?.cancel()
        newsAutoRefreshTask = nil
    }

    private func startNewsAutoRefreshLoop() {
        newsAutoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.newsAutoRefreshInterval))
                if Task.isCancelled { return }
                // End the loop if we've left news + Latest; pause (skip a tick) while a page is open.
                guard currentSearchCategory == "news", newsSortByRecency else { return }
                if showingWebContent || searxInstances.isEmpty { continue }
                await pollForNewStories()
            }
        }
    }

    /// Fetches the latest news for the current query and stashes any genuinely-new stories (by canonical
    /// URL) into `pendingNewsStories`. Goes through the same privacy-gated SearXNGService; silent on
    /// failure. Never mutates the visible list — the user merges via the pill.
    private func pollForNewStories() async {
        let query = lastEffectiveSearchQuery
        guard !query.isEmpty else { return }
        guard let fetched = try? await SearXNGService.shared.searchWithFallback(
            query: query,
            categories: "news",
            instances: searxInstances,
            language: Localization.searchLanguageCode,
            options: SearchContentSafety.shared.searchOptions(pageNo: 1, timeRange: newsTimeRange)
        ) else { return }

        // Bail if the user moved on while the request was in flight.
        guard currentSearchCategory == "news", newsSortByRecency, lastEffectiveSearchQuery == query else { return }

        let processed = SearchResultProcessor.process(raw: fetched.results, query: query, category: "news", append: false)
        let onScreen = Set(searchResults.map { SearchResultProcessor.canonicalURLKey($0.url) })
        let alreadyPending = Set(pendingNewsStories.map { SearchResultProcessor.canonicalURLKey($0.url) })
        let fresh = processed.filter {
            let key = SearchResultProcessor.canonicalURLKey($0.url)
            return !onScreen.contains(key) && !alreadyPending.contains(key)
        }
        if !fresh.isEmpty {
            pendingNewsStories.append(contentsOf: fresh)
        }
    }

    /// Merges the pending new stories into the visible list (the view's Latest sort floats them to the
    /// top) and resets the "Updated" clock. Wired to the "N new stories" pill.
    func mergePendingNewsStories() {
        guard !pendingNewsStories.isEmpty else { return }
        searchResults = SearchResultProcessor.process(
            raw: pendingNewsStories,
            existing: searchResults,
            query: lastSearchQuery,
            category: "news",
            append: true
        )
        pendingNewsStories = []
        newsLastRefreshed = Date()
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
                    options: SearchContentSafety.shared.searchOptions(
                        pageNo: nextPage,
                        timeRange: currentSearchCategory == "news" ? newsTimeRange : nil
                    )
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
        // Any fresh fetch invalidates the live-refresh baseline; it re-arms once results land below.
        stopNewsAutoRefresh()
        pendingNewsStories = []
        showingWebContent = false
        searchPageNo = 1
        canLoadMoreResults = true
        isLoadingMoreResults = false
        consecutiveEmptyLoadMorePages = 0

        // Resolve the knowledge panel concurrently with the search fetch below (it depends only on the
        // query, not the results), so the card is ready by the time results land instead of starting
        // afterwards. The result is committed once the search settles — see commitKnowledgePanelIfReady.
        beginKnowledgePanelResolution()
        beginLocalPackResolution()

        let effectiveQuery = query
        lastEffectiveSearchQuery = effectiveQuery

        // In the All tab, resolve fresh news in parallel so a "Top stories" module can appear among the
        // general results (see AllTabNewsModule). Any other category clears it.
        if category == nil {
            beginAllTabNewsResolution(query: effectiveQuery)
        } else {
            cancelAllTabNews()
        }

        do {
            // Consume the speculative prefetch when it matches what we're actually searching
            // (address-bar submits: category nil, query unchanged by the rewriter). An empty or
            // failed speculation falls through to a normal fetch — never worse than before.
            var fetched: ([SearXNGResult], String?)?
            if category == nil,
               effectiveQuery == query.trimmingCharacters(in: .whitespacesAndNewlines),
               let speculative = SpeculativeSearchPrefetcher.shared.consume(query: effectiveQuery),
               let early = try? await speculative.value,
               !early.0.isEmpty {
                fetched = early
            }

            let (results, usedURL): ([SearXNGResult], String?)
            if let fetched {
                (results, usedURL) = fetched
            } else {
                (results, usedURL) = try await SearXNGService.shared.searchWithFallback(
                    query: effectiveQuery,
                    categories: category,
                    instances: searxInstances,
                    language: Localization.searchLanguageCode,
                    options: SearchContentSafety.shared.searchOptions(
                        pageNo: 1,
                        timeRange: category == "news" ? newsTimeRange : nil
                    )
                )
            }
            lastSearchInstanceURL = usedURL
            searchResults = SearchResultProcessor.process(
                raw: results,
                query: query,
                category: category,
                append: false
            )
            SearchEngineHealthMonitor.shared.recordSearchOutcome(
                resultCount: searchResults.count,
                instanceURL: usedURL
            )
            if category == "news" { newsLastRefreshed = Date() }
            if searchResults.isEmpty {
                var message = category == nil
                    ? "No results found across all your SearXNG instances."
                    : "No results in this category."
                if SearchEngineHealthMonitor.shared.enginesLookDegraded {
                    message += " If this keeps happening, the bundled search engines may be outdated — check for a Searxly update."
                }
                searchErrorMessage = message
            } else {
                // Persist the query for future search history suggestions — but never in Maximum Privacy
                // (that posture means "don't leave search terms on disk"), and only when the dedicated
                // search-history toggle is on.
                let queryHistoryEnabled = UserDefaults.standard.object(forKey: SearchQueryHistoryStore.enabledKey) as? Bool ?? true
                if queryHistoryEnabled && PrivacyManager.shared.appPrivacyMode != .maximum {
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
        commitKnowledgePanelIfReady()
        commitLocalPackIfReady()
        // Arm live auto-refresh if we landed on the news tab in Latest mode.
        syncNewsAutoRefresh()
    }

    // MARK: - Knowledge panel

    func cancelKnowledgePanelTask() {
        knowledgePanelTask?.cancel()
        knowledgePanelTask = nil
        knowledgePanelResolved = nil
    }

    /// Re-evaluate the panel for the current (already-completed) search — used when the user toggles
    /// the feature on while results are on screen.
    func refreshKnowledgePanel() {
        beginKnowledgePanelResolution()
    }

    /// Starts resolving the knowledge panel for `lastSearchQuery`. Safe to call *before* the search
    /// fetch finishes: it runs concurrently, and the result is committed later (gated on real results)
    /// by `commitKnowledgePanelIfReady`. Running it in parallel with the search is what makes the card
    /// appear as soon as results land instead of only starting to resolve afterwards.
    func beginKnowledgePanelResolution() {
        cancelKnowledgePanelTask()

        guard knowledgePanelEnabled,
              !lastSearchQuery.isEmpty,
              currentSearchCategory != "images",
              currentSearchCategory != "videos",
              KnowledgeQueryDetector.classify(lastSearchQuery) != .none else {
            knowledgePanelState = .hidden
            return
        }

        let query = lastSearchQuery
        knowledgePanelState = .loading(query: query)

        let imageInstanceURL = lastSearchInstanceURL ?? searxInstances.first?.url
        knowledgePanelTask = Task {
            let content = await KnowledgePanelService.resolve(query: query, imageInstanceURL: imageInstanceURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.lastSearchQuery == query else { return }
                self.knowledgePanelResolved = (query, content)
                self.commitKnowledgePanelIfReady()
            }
        }
    }

    /// Commits the resolved panel once BOTH the resolution and the search have settled. No-op while
    /// either is still in flight; the later of the two to finish triggers the actual display.
    func commitKnowledgePanelIfReady() {
        guard let resolved = knowledgePanelResolved,
              resolved.query == lastSearchQuery,
              !isLoadingSearch else {
            return
        }

        guard knowledgePanelEnabled,
              !searchResults.isEmpty,
              currentSearchCategory != "images",
              currentSearchCategory != "videos" else {
            knowledgePanelState = .hidden
            return
        }

        if let content = resolved.content {
            knowledgePanelState = .ready(content)
            PrivacyDisclosures.showOnce(
                .knowledgePanel,
                title: "Entity cards use Grokipedia",
                body: "These cards are fetched directly from grokipedia.com, outside your local SearXNG. Turn them off in Settings → Search."
            )
        } else {
            knowledgePanelState = .hidden
        }
    }

    // MARK: - Local pack

    /// Whether the local pack can appear at all right now: a query on the All tab, the gateway configured,
    /// and NOT Maximum Privacy (the map is drawn by Apple, so Maximum blocks the whole feature).
    private var localPackEligible: Bool {
        SearxlyGateway.isConfigured
            && currentSearchCategory == nil
            && PrivacyManager.shared.appPrivacyMode != .maximum
            && !lastSearchQuery.isEmpty
    }

    func cancelLocalPackTask() {
        localPackTask?.cancel()
        localPackTask = nil
        localPackResolved = nil
    }

    /// Re-evaluate the local pack for the current search — used when the feature is toggled on while
    /// results are already on screen.
    func refreshLocalPack() {
        beginLocalPackResolution()
    }

    /// Evaluates the local pack for `lastSearchQuery`. When the feature is ON, resolves places in parallel
    /// with the search (committed later by `commitLocalPackIfReady`). When it's OFF, records the detected
    /// query so an opt-in prompt can be offered once results land. Hidden / no-op when ineligible.
    func beginLocalPackResolution() {
        cancelLocalPackTask()
        localPackDetected = nil

        guard localPackEligible, let detected = LocalPackQueryDetector.detect(lastSearchQuery) else {
            localPackState = .hidden
            return
        }
        localPackDetected = detected

        guard localPackEnabled else {
            // Off → fetch nothing; the opt-in prompt is offered in commit once results are in.
            localPackState = .hidden
            return
        }

        let query = lastSearchQuery
        localPackState = .loading
        localPackTask = Task {
            let data = await LocalPlacesResolver.resolve(query: query, detected: detected)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled, self.lastSearchQuery == query else { return }
                self.localPackResolved = (query, data)
                self.commitLocalPackIfReady()
            }
        }
    }

    /// Settles the local pack once the search has real results. Enabled + resolved → the pack; off → the
    /// opt-in prompt (unless dismissed this session); otherwise hidden. Mirrors the knowledge panel's
    /// "commit only when both the fetch and the search have landed" gating.
    func commitLocalPackIfReady() {
        guard !isLoadingSearch else { return }

        guard localPackEligible,
              !searchResults.isEmpty,
              let detected = localPackDetected,
              LocalPackQueryDetector.detect(lastSearchQuery) == detected else {
            localPackState = .hidden
            return
        }

        if localPackEnabled {
            // Wait for the resolution to land (the task calls back here when it finishes).
            guard let resolved = localPackResolved, resolved.query == lastSearchQuery else { return }
            localPackState = resolved.data.map(LocalPackDisplayState.ready) ?? .hidden
        } else {
            localPackState = localPackPromptDismissed ? .hidden : .prompt(detected)
        }
    }

    /// Enables the local pack from the SERP opt-in prompt, then resolves + shows it for the current query.
    /// Refuses in Maximum Privacy (defensive — the prompt isn't offered there in the first place).
    func enableLocalPackFromPrompt() {
        guard PrivacyManager.shared.appPrivacyMode != .maximum else { return }
        localPackEnabled = true
        Persistence.setLocalPackEnabled(true)
        beginLocalPackResolution()
    }

    /// Dismisses the opt-in prompt and suppresses it for the rest of the session (the user can still turn
    /// the feature on anytime in Settings → Search).
    func dismissLocalPackPrompt() {
        localPackPromptDismissed = true
        localPackState = .hidden
    }

    func setLocalPackEnabled(_ enabled: Bool) {
        // Never enable while Maximum Privacy is active (the map picture is served by Apple).
        if enabled && PrivacyManager.shared.appPrivacyMode == .maximum { return }
        guard enabled != localPackEnabled else { return }
        localPackEnabled = enabled
        Persistence.setLocalPackEnabled(enabled)
        if !enabled {
            cancelLocalPackTask()
            localPackDetected = nil
            localPackState = .hidden
        } else if !searchResults.isEmpty {
            refreshLocalPack()
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

    func highlightResult(url: String) {
        highlightedResultURL = url
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1450))
            if highlightedResultURL == url { highlightedResultURL = nil }
        }
    }

    func searchMyHistory(query: String) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Array(history.sorted { $0.date > $1.date }.prefix(12)) }
        let q = trimmed.lowercased()
        let filtered = history.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        return Array(filtered.sorted { $0.date > $1.date }.prefix(15))
    }
}
