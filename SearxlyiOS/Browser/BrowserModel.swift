//
//  BrowserModel.swift
//  SearxlyIOS
//
//  One browser tab. A tab is in one of three content modes:
//    .home    — the Searxly start page
//    .results — a NATIVE search-results page (SwiftUI, from the SearXNG JSON API) — the macOS-parity SERP
//    .web     — a page loaded in the WKWebView
//  A search renders our own results; tapping one opens it in the web view. Back walks web → results → home.
//

import SwiftUI
import WebKit
import UIKit
import Observation

enum TabContent: Equatable { case home, results, web }
enum SearchPhase { case idle, loading, loaded, failed(String) }

enum SearchScope: String, CaseIterable, Identifiable {
    // Order = the scope bar order: News sits right next to All (the general tab).
    case web, news, images, videos
    var id: String { rawValue }
    @MainActor var label: String {
        switch self {
        case .web: L("All")
        case .news: L("News")
        case .images: L("Images")
        case .videos: L("Videos")
        }
    }
    var icon: String {
        switch self {
        case .web: "magnifyingglass"
        case .news: "newspaper"
        case .images: "photo"
        case .videos: "play.rectangle"
        }
    }
    var categories: String {
        switch self {
        case .web: "general"
        case .news: "news"
        case .images: "images"
        case .videos: "videos"
        }
    }
}

@MainActor
@Observable
final class BrowserModel: Identifiable {

    nonisolated let id = UUID()

    let webView: WKWebView

    /// Private tabs share one session-scoped ephemeral data store (Safari-style): cookies and
    /// storage live only in memory, are shared between private tabs, and vanish with the app.
    let isPrivate: Bool
    private static let privateDataStore = WKWebsiteDataStore.nonPersistent()

    var content: TabContent = .home

    // Native SERP state
    var searchQuery: String = ""
    var results: [SearXNGResult] = []
    /// SERP AI Overview state, owned HERE (stable per tab) rather than in the card's @State — so it
    /// survives the results `List` recycling the card mid-generation. See AIOverviewModel.
    let aiOverview = AIOverviewModel()
    /// SearXNG's related-search suggestions for the current query (AI-Overview follow-ups).
    private(set) var searchSuggestions: [String] = []
    /// Fresh news for the current All query, resolved in the background to power a Google-style
    /// "Top stories" module among the general results (empty unless the query is genuinely newsy).
    private(set) var allTabNews: [SearXNGResult] = []
    @ObservationIgnored private var allTabNewsTask: Task<Void, Never>?
    var searchPhase: SearchPhase = .idle
    var scope: SearchScope = .web
    var isLoadingMore = false
    private var pageNo = 1
    private(set) var canLoadMore = false

    // Web view state
    var urlText: String = ""
    var isLoading: Bool = false
    var progress: Double = 0
    var pageTitle: String = ""

    /// Safari-style minimized chrome: set while scrolling down a web page, cleared on scroll-up /
    /// top / navigation. The bar reads this and shrinks to a slim pill (parameter changes only).
    /// The web view runs UNDER the floating bar (no opaque band), so the scroll inset tracks
    /// the bar's current height.
    private(set) var chromeCollapsed = false {
        didSet { applyBottomInset() }
    }

    /// Extra bottom inset beyond the automatic home-indicator adjustment: full bar vs mini pill.
    private static let expandedBarInset: CGFloat = 68
    private static let collapsedBarInset: CGFloat = 16

    private func applyBottomInset() {
        let extra = chromeCollapsed ? Self.collapsedBarInset : Self.expandedBarInset
        webView.scrollView.contentInset.bottom = extra
        webView.scrollView.verticalScrollIndicatorInsets.bottom = extra
    }
    /// Scroll bookkeeping is @ObservationIgnored: it mutates on EVERY scroll frame, and tracked
    /// mutations would invalidate every observing view 60–120×/s — the main scroll-lag source.
    @ObservationIgnored private var lastScrollY: CGFloat = 0
    @ObservationIgnored private var scrollAccumulated: CGFloat = 0

    /// Last rendered look of the page — the tab-switcher grid card (Safari-style).
    private(set) var snapshot: UIImage?

    /// "Request Desktop Website" — remembered PER SITE (PerSiteSettings), like Safari.
    var isDesktopSite: Bool {
        PerSiteSettings.shared.settings(forHost: webView.url?.host).desktopMode ?? false
    }

    /// Set by TabsModel — routes target=_blank / pop-up requests into a new tab.
    var onOpenInNewTab: ((URL) -> Void)?

    /// Set by TabsModel — opens a new tab WITHOUT switching to it (queue a result while reading).
    var onOpenInNewTabBackground: ((URL) -> Void)?

    // MARK: - Shields state

    /// Tracker/ad requests attempted on the current page (see TrackerTally — a floor, not an audit).
    private(set) var pageBlockedCount = 0

    /// Set when a non-web URL (tel:, mailto:, app link…) wants to leave the app — drives a confirm alert.
    var pendingExternalURL: URL?

    /// Set when an HTTPS-Only upgrade failed — drives the "site doesn't support HTTPS" alert.
    var httpFallbackURL: URL?

    /// Set when a main-frame load fails outright — drives the native error page (Retry / Go Back).
    var loadError: String?

    /// Extracted article for Reader mode (set by prepareReader → drives the reader sheet).
    var readerArticle: ReaderArticle?
    /// True while extraction runs (menu shows a spinner / disables re-tap).
    private(set) var readerLoading = false

    /// Routes "Open in New Private Tab" from link context menus (set by TabsModel).
    var onOpenInNewPrivateTab: ((URL) -> Void)?

    /// Whether the network rule lists are currently detached for the visited site.
    private(set) var shieldsLoweredForPage = false

    private var webCanGoBack = false
    private var webCanGoForward = false
    private var observations: [NSKeyValueObservation] = []
    private var searchTask: Task<Void, Never>?
    private let uiDelegate = WebUIDelegate()
    private let navigationDelegate = WebNavigationDelegate()
    private let tallyHandler = TallyMessageHandler()
    private let refreshControl = UIRefreshControl()

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let configuration = BrowserModel.makeConfiguration(isPrivate: isPrivate)
        TrackerTally.apply(to: configuration, handler: tallyHandler)
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true  // system Find on Page (⌘F / ⋯ menu)
        webView.allowsLinkPreview = true         // long-press link peek + our context actions

        uiDelegate.model = self
        webView.uiDelegate = uiDelegate
        navigationDelegate.model = self
        webView.navigationDelegate = navigationDelegate
        tallyHandler.model = self

        // Pull-to-refresh on web pages.
        refreshControl.addAction(UIAction { [weak self] _ in self?.webView.reload() }, for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // The web view extends UNDER the floating bar; left automatic, UIKit would re-inset the
        // content by the bar's whole safe-area contribution and paint the gap with the (black)
        // under-page background — the exact band we're avoiding. We own the insets instead.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.scrollsToTop = true  // tap the status bar → jump to top (Safari)
        applyBottomInset()
        observe()
    }

    // MARK: - Address-bar text

    /// Shown in the address bar when it isn't being edited.
    var displayText: String {
        switch content {
        case .home:    return ""
        case .results: return searchQuery
        case .web:     return webView.url?.host ?? urlText
        }
    }

    /// Shown when the address bar gains focus (full value, editable).
    var editText: String {
        switch content {
        case .home:    return ""
        case .results: return searchQuery
        case .web:     return urlText
        }
    }

    // MARK: - Navigation intents

    /// Toolbar-level back availability (web history, or stepping results → home).
    var canGoBack: Bool { content != .home }
    var canGoForward: Bool { content == .web && webCanGoForward }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.directURL(trimmed) { load(url) } else { runSearch(trimmed) }
    }

    /// A URL only when the input clearly is one (explicit scheme or a bare dotted domain); else nil → search.
    static func directURL(_ input: String) -> URL? {
        if input.hasPrefix("http://") || input.hasPrefix("https://") { return URL(string: input) }
        if !input.contains(" "), input.contains("."), let u = URL(string: "https://\(input)") { return u }
        return nil
    }

    func load(_ url: URL) {
        content = .web
        chromeCollapsed = false
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func open(_ result: SearXNGResult) {
        guard let url = URL(string: result.url) else { return }
        load(url)
    }

    func goBack() {
        chromeCollapsed = false
        switch content {
        case .web:
            if webView.canGoBack { webView.goBack() }
            else if !searchQuery.isEmpty { content = .results }
            else { content = .home }
        case .results:
            content = .home
        case .home:
            break
        }
    }

    func goForward() {
        if content == .web { webView.goForward() }
    }

    // MARK: - Back/forward history (Safari's long-press menus)

    /// Recent-first back stack entries, only meaningful in web mode.
    var backHistory: [WKBackForwardListItem] {
        content == .web ? webView.backForwardList.backList.reversed() : []
    }

    var forwardHistory: [WKBackForwardListItem] {
        content == .web ? webView.backForwardList.forwardList : []
    }

    func go(to item: WKBackForwardListItem) {
        chromeCollapsed = false
        content = .web
        webView.go(to: item)
    }

    static func historyItemLabel(_ item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.url.host ?? item.url.absoluteString
    }

    // MARK: - Page tools (Safari parity)

    /// Presents the system Find on Page UI over the web view.
    func findOnPage() {
        guard content == .web else { return }
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Safari's "Request Desktop/Mobile Website" — persists per host, applied by the
    /// navigation delegate's preferences hook on every load of that site.
    func toggleDesktopSite() {
        guard let host = webView.url?.host else { return }
        PerSiteSettings.shared.setDesktopMode(!isDesktopSite, forHost: host)
        if content == .web { webView.reloadFromOrigin() }
    }

    func reloadOrStop() {
        switch content {
        case .web:     if isLoading { webView.stopLoading() } else { webView.reload() }
        case .results: runSearch(searchQuery)
        case .home:    break
        }
    }

    /// Recovers a tab whose WebContent process was terminated (memory pressure or a page bug) by
    /// reloading the current item in place — otherwise the tab is left blank. Rate-limited so a page
    /// that reliably kills WebContent can't spin us in a reload loop.
    @ObservationIgnored private var lastCrashRecovery: Date = .distantPast
    func recoverFromWebContentCrash() {
        guard content == .web else { return }
        guard Date.now.timeIntervalSince(lastCrashRecovery) > 5 else { return }
        lastCrashRecovery = .now
        if webView.url != nil {
            webView.reload()
        } else if let item = webView.backForwardList.currentItem {
            webView.go(to: item)
        }
    }

    // MARK: - Native search

    func runSearch(_ query: String, scope: SearchScope? = nil) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let scope { self.scope = scope }
        searchQuery = q
        content = .results
        chromeCollapsed = false
        searchPhase = .loading
        if !isPrivate, SearchSettings.shared.saveHistory {
            LibraryStore.shared.recordSearch(q)
        }
        results = []
        searchSuggestions = []
        pageNo = 1
        canLoadMore = false
        isLoadingMore = false
        searchTask?.cancel()
        searchTask = Task { await performSearch(reset: true) }

        // A Google-style "Top stories" module among the All results: resolve fresh news for the query
        // in the background. Only on the All tab, never in private tabs (it's an extra instance call).
        allTabNewsTask?.cancel()
        allTabNews = []
        if self.scope == .web, !isPrivate { beginAllTabNews(query: q) }
    }

    /// Resolves fresh news for the All query in the background. Shares the session SERP cache with the
    /// News tab (so opening News afterward is instant). Silent on failure — the module just won't show.
    private func beginAllTabNews(query: String) {
        let q = query
        allTabNewsTask = Task { @MainActor in
            guard let (hits, _) = try? await Self.fetchHits(q, categories: "news", page: 1), !hits.isEmpty else { return }
            guard !Task.isCancelled, self.scope == .web, self.searchQuery == q else { return }
            self.allTabNews = SearchResultProcessor.process(raw: hits, query: q, category: "news", append: false)
        }
    }

    /// Switch Web ⇄ Images for the current query.
    func setScope(_ newScope: SearchScope) {
        guard newScope != scope else { return }
        if searchQuery.isEmpty { scope = newScope; return }
        runSearch(searchQuery, scope: newScope)
    }

    /// Swipe-driven scope paging (Web ↔ Images ↔ Videos ↔ News), clamped at the ends.
    func stepScope(forward: Bool) {
        let all = SearchScope.allCases
        guard let i = all.firstIndex(of: scope) else { return }
        let next = forward ? min(i + 1, all.count - 1) : max(i - 1, 0)
        guard next != i else { return }
        setScope(all[next])
    }

    // MARK: - Page tools (text zoom / clean link / duplicate support)

    /// Safari's aA text-size control, remembered per site.
    private(set) var textZoom: CGFloat = 1.0

    func adjustTextZoom(_ delta: CGFloat) {
        setTextZoom(textZoom + delta)
    }

    func resetTextZoom() {
        setTextZoom(1.0)
    }

    private func setTextZoom(_ value: CGFloat) {
        textZoom = min(2.0, max(0.6, value))
        webView.pageZoom = textZoom
        PerSiteSettings.shared.setTextZoom(Double(textZoom), forHost: webView.url?.host)
    }

    /// The current URL with tracking parameters stripped — for "Copy Clean Link".
    var cleanLinkString: String? {
        guard let raw = currentURLString, let url = URL(string: raw) else { return nil }
        return (NavigationGuard.strippingTrackingParams(from: url) ?? url).absoluteString
    }

    /// Fetch and append the next page (infinite scroll).
    func loadMore() {
        guard canLoadMore, !isLoadingMore else { return }
        guard case .loaded = searchPhase else { return }
        isLoadingMore = true
        searchTask = Task { await performSearch(reset: false) }
    }

    /// Session SERP cache: raw hits + suggestions keyed by query/scope/page/settings. Makes scope
    /// flips, re-searches, and back-to-results instant, and lets a background prefetch of page 2
    /// turn infinite scroll into a cache hit.
    private static var serpCache: [String: (hits: [SearXNGResult], suggestions: [String], at: Date)] = [:]
    private static let serpCacheTTL: TimeInterval = 8 * 60
    private static let serpCacheCap = 30

    private static func cacheKey(_ q: String, _ categories: String, _ page: Int) -> String {
        let s = SearchSettings.shared
        return "\(q.lowercased())|\(categories)|\(page)|\(s.safeSearch.rawValue)|\(s.language)"
    }

    private static func cached(_ key: String) -> (hits: [SearXNGResult], suggestions: [String])? {
        guard let entry = serpCache[key], Date().timeIntervalSince(entry.at) < serpCacheTTL else { return nil }
        return (entry.hits, entry.suggestions)
    }

    private static func store(_ hits: [SearXNGResult], suggestions: [String], key: String) {
        serpCache[key] = (hits, suggestions, Date())
        if serpCache.count > serpCacheCap {
            // Drop the stalest entries down to the cap.
            for (k, _) in serpCache.sorted(by: { $0.value.at < $1.value.at }).prefix(serpCache.count - serpCacheCap) {
                serpCache.removeValue(forKey: k)
            }
        }
    }

    /// Instance that last served results this session — tried first so a dead primary isn't
    /// re-hit on every search.
    private static var preferredInstance: String?

    @discardableResult
    private static func fetchHits(_ q: String, categories: String, page: Int) async throws -> (hits: [SearXNGResult], suggestions: [String]) {
        let key = cacheKey(q, categories, page)
        if let cached = cached(key) { return cached }
        let s = SearchSettings.shared

        // Try the session-preferred instance first, then the configured order — rotate past any
        // that are down/rate-limited/not serving JSON before surfacing an error.
        var order = s.searchInstances
        if let pref = preferredInstance, let i = order.firstIndex(of: pref), i != 0 {
            order.remove(at: i); order.insert(pref, at: 0)
        }

        var lastError: Error = SearxngClientError.invalidResponse
        for instance in order {
            do {
                let response = try await SearxngClient().searchDetailed(
                    q, base: instance, categories: categories,
                    safeSearch: s.safeSearch.rawValue, language: s.language, pageNo: page
                )
                guard !response.results.isEmpty || order.last == instance else {
                    lastError = SearxngClientError.notJSON
                    continue  // empty from a backup: try the next before accepting "no results"
                }
                preferredInstance = instance
                store(response.results, suggestions: response.suggestions, key: key)
                return (response.results, response.suggestions)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func performSearch(reset: Bool) async {
        let page = reset ? 1 : pageNo + 1
        do {
            let (hits, suggestions) = try await Self.fetchHits(searchQuery, categories: scope.categories, page: page)
            if Task.isCancelled { return }
            // Same post-fetch pipeline as macOS (SearxlyShared): canonical dedup, SafeSearch
            // filtering, client-side re-ranking, domain diversity, Grokipedia-first policy.
            let processed = SearchResultProcessor.process(
                raw: hits,
                existing: results,
                query: searchQuery,
                category: scope.categories,
                append: !reset
            )
            if reset {
                results = processed
                searchSuggestions = suggestions
                searchPhase = processed.isEmpty ? .failed("No results for “\(searchQuery)”.") : .loaded
            } else {
                results = processed
                isLoadingMore = false
            }
            pageNo = page
            canLoadMore = !hits.isEmpty

            // Warm the next page in the background: by the time the user scrolls to the end,
            // loadMore is a cache hit instead of a network round-trip.
            if reset, canLoadMore {
                let q = searchQuery, cats = scope.categories
                Task.detached(priority: .utility) {
                    _ = try? await BrowserModel.fetchHits(q, categories: cats, page: page + 1)
                }
            }
        } catch {
            if Task.isCancelled { return }
            isLoadingMore = false
            if reset {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? "Search failed. Check your connection, or the instance in Settings."
                searchPhase = .failed(msg)
            } else {
                canLoadMore = false
            }
        }
    }

    // MARK: - Tab snapshot (Safari-style grid card)

    /// Captures the web view's current look for the tab grid. Called when a page finishes loading
    /// and when the user leaves the tab / opens the switcher.
    func captureSnapshot() {
        guard content == .web, webView.bounds.width > 0, !isLoading else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }

    #if DEBUG
    @ObservationIgnored private var debugCollapseLock = false

    /// Headless-verification hook: forces the collapsed-chrome look and pins it (simctl can't send
    /// scrolls, and the page's own offset events at y≈0 would immediately re-expand it).
    func debugForceCollapsed() {
        debugCollapseLock = true
        chromeCollapsed = true
    }
    #endif

    // MARK: - Bookmarks (current page)

    var currentURLString: String? {
        guard content == .web, let u = webView.url, (u.scheme?.hasPrefix("http") ?? false) else { return nil }
        return u.absoluteString
    }

    var isCurrentBookmarked: Bool {
        guard let s = currentURLString else { return false }
        return LibraryStore.shared.isBookmarked(s)
    }

    func toggleBookmarkCurrent() {
        guard let s = currentURLString else { return }
        LibraryStore.shared.toggleBookmark(url: s, title: pageTitle)
    }

    #if DEBUG
    /// Renders the native SERP from canned JSON — used to verify the results UI without a live
    /// JSON-enabled instance (public instances rate-limit/disable the JSON API). Set the env var
    /// `SEARXLY_DEMO_QUERY` when launching to trigger it.
    func loadDemoResults(for query: String) {
        searchQuery = query
        content = .results
        let json = """
        {"results":[
          {"title":"Swift.org — Welcome to Swift.org","url":"https://www.swift.org/","content":"Swift is a powerful and intuitive programming language for iOS, macOS, and beyond. Writing Swift code is interactive and fun, the syntax is concise yet expressive."},
          {"title":"Swift (programming language) — Wikipedia","url":"https://en.wikipedia.org/wiki/Swift_(programming_language)","content":"Swift is a high-level general-purpose, multi-paradigm, compiled programming language created by Apple Inc. and the open-source community, first released in 2014."},
          {"title":"Swift — Apple Developer","url":"https://developer.apple.com/swift/","content":"Swift is a robust and intuitive programming language created by Apple for building apps across all Apple platforms, with safety and speed in mind."},
          {"title":"The Swift Programming Language — Documentation","url":"https://docs.swift.org/swift-book/","content":"The definitive guide to Swift. Start with the basics and work through the language feature by feature, from values and collections to concurrency and macros."},
          {"title":"Hacking with Swift — learn to code iOS apps","url":"https://www.hackingwithswift.com/","content":"Free Swift tutorials by Paul Hudson, covering SwiftUI, UIKit, and the Swift language with hands-on projects and worked examples."}
        ]}
        """.data(using: .utf8)!
        results = (try? JSONDecoder().decode(SearXNGResponse.self, from: json))?.results ?? []
        searchPhase = results.isEmpty ? .failed("No demo results.") : .loaded
    }
    #endif

    // MARK: - Configuration

    private static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isPrivate { config.websiteDataStore = privateDataStore }

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        config.applicationNameForUserAgent = "Version/17.4 Mobile/15E148 Safari/604.1"
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.upgradeKnownHostsToHTTPS = true

        // Privacy shields (each checks its own ShieldSettings switch).
        ContentBlockManager.shared.apply(to: config)
        YouTubeAdBlocker.apply(to: config)
        FingerprintShield.apply(to: config)
        CookieBannerShield.apply(to: config)
        return config
    }

    // MARK: - Shields

    /// Called from the navigation delegate for every allowed main-frame navigation: resets the
    /// per-page tally, applies remembered site prefs (zoom), and attaches/detaches the network
    /// rule lists per the site exception list.
    func applyPerSiteShields(for url: URL?) {
        pageBlockedCount = 0

        // Remembered text zoom for this host (1.0 when none stored).
        let site = PerSiteSettings.shared.settings(forHost: url?.host)
        textZoom = CGFloat(site.textZoom ?? 1.0)
        webView.pageZoom = textZoom

        guard ShieldSettings.shared.blockAdsAndTrackers else { return }
        let lowered = !ShieldSettings.shared.shieldsEnabled(forHost: url?.host)
        guard lowered != shieldsLoweredForPage else { return }
        shieldsLoweredForPage = lowered
        ContentBlockManager.shared.setNetworkRules(!lowered, for: webView.configuration.userContentController)
    }

    /// Brave-style "Shred": erase this site's cookies, caches, and storage, then reload it fresh.
    func shredCurrentSite() {
        guard let host = webView.url?.host else { return }
        let base = ShieldSettings.normalizedHost(host) ?? host
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            MainActor.assumeIsolated {  // WKWebsiteDataStore completions arrive on main
                let targets = records.filter { record in
                    let name = record.displayName.lowercased()
                    return name == base || name.hasSuffix(".\(base)") || base.hasSuffix(".\(name)")
                }
                let store = self?.webView.configuration.websiteDataStore
                store?.removeData(ofTypes: types, for: targets) {
                    MainActor.assumeIsolated { _ = self?.webView.reloadFromOrigin() }
                }
            }
        }
        Haptics.tap()
    }

    /// Page-menu toggle: lower/raise shields for the visited site (persisted), then reload.
    func toggleShieldsForCurrentSite() {
        guard let host = webView.url?.host else { return }
        let currentlyOn = ShieldSettings.shared.shieldsEnabled(forHost: host)
        ShieldSettings.shared.setShields(!currentlyOn, forHost: host)
        webView.reloadFromOrigin()
    }

    var shieldsOnForCurrentSite: Bool {
        ShieldSettings.shared.shieldsEnabled(forHost: webView.url?.host)
    }

    func recordBlockedTrackers(_ n: Int, domains: [String]) {
        guard n > 0, !shieldsLoweredForPage else { return }
        pageBlockedCount += n
        ShieldSettings.shared.addBlockedTrackers(n, domains: domains)
    }

    // MARK: - Hibernation (memory pressure)

    /// Where this tab "really is" — survives hibernation's about:blank placeholder.
    var sessionURL: URL? {
        if let hibernatedURL { return hibernatedURL }
        guard content == .web, let u = webView.url, u.scheme?.hasPrefix("http") == true else { return nil }
        return u
    }

    @ObservationIgnored private var hibernatedURL: URL?

    /// Under memory pressure, background tabs park on about:blank (snapshot already captured for
    /// the grid) and reload their page when re-activated — losing scroll position, keeping the tab.
    func hibernate() {
        guard content == .web, !isLoading, hibernatedURL == nil,
              let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        captureSnapshot()
        hibernatedURL = url
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func reviveIfNeeded() {
        guard let url = hibernatedURL else { return }
        hibernatedURL = nil
        load(url)
    }

    /// Restore a background tab WITHOUT loading it: the URL is parked (and revived on first activation),
    /// so restoring a session of many tabs doesn't fire many page loads at launch — only the active tab
    /// loads. This is the big launch-speed win for people who keep lots of tabs open.
    func parkForRestore(_ url: URL) {
        hibernatedURL = url
        urlText = url.absoluteString
        content = .web
    }

    // MARK: - External apps & HTTPS-Only fallback (driven by WebNavigationDelegate)

    func requestExternalOpen(_ url: URL) {
        pendingExternalURL = url
    }

    func confirmExternalOpen() {
        guard let url = pendingExternalURL else { return }
        pendingExternalURL = nil
        UIApplication.shared.open(url)
    }

    func offerHTTPFallback(to url: URL) {
        httpFallbackURL = url
    }

    // MARK: - Reader mode

    var canUseReader: Bool { content == .web && !isLoading }

    /// Extracts the article and, on success, sets `readerArticle` (the caller presents the sheet).
    /// On failure sets a soft error so the UI can say "no readable article here".
    func prepareReader() async -> Bool {
        guard content == .web else { return false }
        readerLoading = true
        defer { readerLoading = false }
        if let article = await ReaderExtractor.extract(from: webView) {
            readerArticle = article
            return true
        }
        return false
    }

    /// User chose "Continue with HTTP" — remember the host for this session and load insecurely.
    func continueWithHTTP() {
        guard let url = httpFallbackURL else { return }
        httpFallbackURL = nil
        if let host = url.host { navigationDelegate.allowHTTP(forHost: host) }
        load(url)
    }

    // MARK: - Observation

    private func observe() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = wv.isLoading
                    if !wv.isLoading {
                        self?.refreshControl.endRefreshing()
                        // Favicon capture is allowed ONLY here — for the page actually being
                        // visited (see FaviconStore's privacy rule). Private tabs leave no trace.
                        if self?.isPrivate == false { FaviconStore.shared.captureIfNeeded(from: wv) }
                        self?.captureSnapshot()
                    }
                }
            },
            // Safari-style chrome minimizing: collapse on a deliberate downward scroll, expand on
            // scroll-up or near the top. Accumulated deltas (with hysteresis) so tiny jitters and
            // bounce don't flap the bar.
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    self?.handleScroll(y: scrollView.contentOffset.y)
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pageTitle = wv.title ?? ""
                    if !self.isPrivate, SearchSettings.shared.saveHistory, let u = wv.url {
                        LibraryStore.shared.updateTitle(url: u.absoluteString, title: wv.title ?? "")
                    }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.webCanGoBack = wv.canGoBack
                    self.webCanGoForward = wv.canGoForward
                    if let u = wv.url {
                        self.urlText = u.absoluteString
                        if !self.isPrivate, SearchSettings.shared.saveHistory {
                            LibraryStore.shared.recordVisit(url: u.absoluteString, title: self.pageTitle)
                        }
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.webCanGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.webCanGoForward = wv.canGoForward }
            },
        ]
    }

    private func handleScroll(y: CGFloat) {
        let delta = y - lastScrollY
        lastScrollY = y
        guard content == .web else { return }
        #if DEBUG
        if debugCollapseLock { return }
        #endif

        // Near the top (or rubber-banding): always show full chrome.
        if y <= 60 {
            scrollAccumulated = 0
            if chromeCollapsed { chromeCollapsed = false }
            return
        }

        if delta > 0 {
            scrollAccumulated = max(0, scrollAccumulated) + delta
            if scrollAccumulated > 70, !chromeCollapsed { chromeCollapsed = true }
        } else if delta < 0 {
            scrollAccumulated = min(0, scrollAccumulated) + delta
            if scrollAccumulated < -50, chromeCollapsed { chromeCollapsed = false }
        }
    }

    /// Expand the chrome (tap on the mini pill / focusing the field).
    func expandChrome() {
        chromeCollapsed = false
        scrollAccumulated = 0
    }

}

// MARK: - Tracker tally bridge

/// Receives batched "tracker request attempted" counts from the TrackerTally user script.
/// A separate NSObject because WKScriptMessageHandler is retained by the user content controller
/// (the weak model reference breaks the cycle).
final class TallyMessageHandler: NSObject, WKScriptMessageHandler {
    weak var model: BrowserModel?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == TrackerTally.messageHandlerName,
              let body = message.body as? [String: Any] else { return }
        let count = (body["c"] as? NSNumber)?.intValue ?? 0
        guard count > 0, count < 500 else { return }  // sanity-bound anything page JS could forge
        // Domains are page-forgeable strings — cap the list and each entry's length.
        let domains = ((body["d"] as? [String]) ?? [])
            .prefix(20)
            .filter { $0.count < 60 && $0.contains(".") }
        MainActor.assumeIsolated {
            model?.recordBlockedTrackers(count, domains: Array(domains))
        }
    }
}

// MARK: - Pop-up / new-window handling

/// We never spawn a secondary WKWebView. Real `target=_blank` links are routed somewhere useful;
/// blank/JS pop-ups are dropped. Also provides Safari-style link context menus.
final class WebUIDelegate: NSObject, WKUIDelegate {
    weak var model: BrowserModel?

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }

        if SearchSettings.shared.blockPopups {
            // Pop-ups blocked → open the target in THIS tab so legit links still work, no window stacking.
            webView.load(URLRequest(url: url))
        } else if let open = model?.onOpenInNewTab {
            open(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - Long-press link menu (Safari parity: new tab / private tab / copy / share)

    func webView(_ webView: WKWebView,
                 contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else { return nil }
        let model = self.model
        // webView is captured weakly ONCE at the provider level (the Share action below needs
        // it as a presentation anchor; a strong capture here would be redeclared-ownership noise).
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak webView] _ in
            var actions: [UIAction] = [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    model?.onOpenInNewTab?(url)
                },
                UIAction(title: "Open in Private Tab", image: UIImage(systemName: "hand.raised")) { _ in
                    model?.onOpenInNewPrivateTab?(url)
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = url.absoluteString
                },
            ]
            actions.append(
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    guard let webView else { return }
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    activity.popoverPresentationController?.sourceView = webView  // iPad anchor
                    webView.window?.rootViewController?
                        .presentedViewController?.present(activity, animated: true)
                        ?? webView.window?.rootViewController?.present(activity, animated: true)
                }
            )
            return UIMenu(children: actions)
        }
    }
}
