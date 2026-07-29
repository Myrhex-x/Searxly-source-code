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

    /// Erases everything the shared private store holds. Called when the user leaves Private Mode
    /// (and on Burn) so the private session is gone "as if it never happened" — the store itself is
    /// non-persistent (memory-only), this just empties it while the app keeps running.
    static func wipePrivateData() {
        privateDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

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

    /// Whether this tab has audio or video playing right now, and whether a video is in Picture in
    /// Picture. Fed live by the MediaPlayback watcher script — see the note there on why this is
    /// tracked continuously instead of being probed when the app backgrounds.
    var isPlayingMedia = false
    var isInPictureInPicture = false

    /// Safari-style minimized chrome: set while scrolling down a web page, cleared on scroll-up /
    /// top / navigation. The bar reads this and shrinks to a slim pill (parameter changes only).
    ///
    /// Deliberately has NO side effect on the page. It used to retune the scroll inset and re-inject
    /// the bottom-lift stylesheet on every flip, but the flip happens mid-drag: rewriting
    /// `body{padding-bottom}` there forces a full document reflow while the scroll view is moving,
    /// which makes `position: fixed`/`sticky` players (YouTube et al) visibly lag the page. The page
    /// now sees one stable geometry for the whole scroll; only the chrome's own appearance changes.
    private(set) var chromeCollapsed = false

    /// End-of-scroll pad, sized for the EXPANDED bar and held constant in both states. The web
    /// view now extends UNDER the floating chrome (full-bleed, Safari-style) with inset
    /// adjustment off, so this must clear the whole bar stack by itself — same 110 as
    /// `chromeLiftPoints`, which is the measured worst case.
    private static let barInset: CGFloat = 110

    /// Clearance handed to the page for bottom-pinned consent UI. Constant for the same reason as
    /// `barInset`: the expanded bar is the worst case, so 110 clears the chrome in both states.
    private static let chromeLiftPoints: CGFloat = 110

    /// Last lift height we pushed into the page — skip re-eval when it hasn't actually changed
    /// (reset to -1 on a fresh document so the new page gets the stylesheet).
    @ObservationIgnored private var lastChromeLiftPoints: Int = -1

    private func applyBottomInset() {
        webView.scrollView.contentInset.bottom = Self.barInset
        webView.scrollView.verticalScrollIndicatorInsets.bottom = Self.barInset
        // Belt-and-suspenders: lift fixed/sticky bottom banners (consent walls) if a site still
        // pins to the visual viewport edge after layout.
        injectBottomChromeLift(points: Self.chromeLiftPoints)
    }

    /// Injects a small stylesheet so `position: fixed; bottom: 0` consent UI clears the address bar.
    private func injectBottomChromeLift(points: CGFloat) {
        let h = Int(ceil(points))
        // JS evaluation on every scroll-driven chrome flip was measurable main-thread work; only re-run
        // when the lift distance actually changes (or after a fresh page finish — force via reset).
        guard h != lastChromeLiftPoints else { return }
        lastChromeLiftPoints = h
        let js = """
        (function(){
          var h = \(h);
          var id = '__searxly_bottom_chrome';
          var el = document.getElementById(id);
          if (!el) {
            el = document.createElement('style');
            el.id = id;
            (document.documentElement || document).appendChild(el);
          }
          el.textContent =
            'html{scroll-padding-bottom:' + h + 'px!important;}' +
            'body{padding-bottom:max(' + h + 'px, env(safe-area-inset-bottom, 0px))!important;' +
            'box-sizing:border-box!important;}' +
            /* Common consent / cookie footers pinned to the bottom edge */
            '[class*="cookie" i][style*="fixed" i],' +
            '[id*="cookie" i][style*="fixed" i],' +
            '[class*="consent" i][style*="fixed" i],' +
            '[id*="consent" i][style*="fixed" i],' +
            '[class*="gdpr" i],' +
            '[id*="gdpr" i],' +
            '[class*="onetrust" i],' +
            '[id*="onetrust" i],' +
            '#onetrust-banner-sdk,' +
            '.ot-sdk-container,' +
            '[class*="CookieBanner" i],' +
            '[class*="cookie-banner" i],' +
            '[class*="cc-window" i],' +
            '.cc-banner,' +
            '[aria-label*="cookie" i][style*="fixed" i],' +
            '[role="dialog"][style*="fixed" i][style*="bottom" i]{' +
            '  bottom: ' + h + 'px !important;' +
            '  margin-bottom: 0 !important;' +
            '}';
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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
    private let mediaHandler = MediaMessageHandler()
    private let refreshControl = UIRefreshControl()

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let configuration = BrowserModel.makeConfiguration(isPrivate: isPrivate)
        TrackerTally.apply(to: configuration, handler: tallyHandler)
        MediaPlayback.apply(to: configuration, handler: mediaHandler)
        let webView = SelectionActionsWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        // ON = Safari's real interactive back/forward peek for page↔page history (and forward).
        // WKWebViewRepresentable layers a gated left-edge recognizer on top that ONLY fires at the
        // history boundary — to drop back to the native search results — and otherwise stands down so
        // WebKit's peek is untouched.
        webView.allowsBackForwardNavigationGestures = true
        webView.isFindInteractionEnabled = true  // system Find on Page (⌘F / ⋯ menu)
        webView.allowsLinkPreview = true         // long-press link peek + our context actions

        uiDelegate.model = self
        webView.uiDelegate = uiDelegate
        navigationDelegate.model = self
        webView.navigationDelegate = navigationDelegate
        tallyHandler.model = self
        mediaHandler.model = self
        // Text-selection edit-menu actions (Explain This / Translate This) land here; the
        // browser shell observes these fields and presents the matching sheet/popover.
        webView.onExplainSelection = { [weak self] text in self?.pendingSelectionExplain = text }
        webView.onTranslateSelection = { [weak self] text in self?.pendingSelectionTranslation = text }

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
        if let bang = SearchBangs.resolve(trimmed) { load(bang) }
        else if let url = Self.directURL(trimmed) { load(url) }
        else { runSearch(trimmed) }
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
        // An explicit navigation supersedes anything parked by hibernation: without this, a tab that
        // was parked and then typed into would be yanked back to the old page (and, since we now
        // keep the whole session, the old back stack) the next time it was activated.
        hibernatedURL = nil
        hibernatedState = nil
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

    /// Presents the system Find on Page UI over the web view (Safari-grade navigator).
    func findOnPage() {
        guard content == .web else { return }
        // Ensure Find is enabled and the web view can become first responder before presenting.
        webView.isFindInteractionEnabled = true
        webView.becomeFirstResponder()
        // Present on the next run loop so first-responder settlement doesn't race the navigator.
        DispatchQueue.main.async {
            self.webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
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
        // Resolve the query's official entity once per search (offline DB lookup) so rows can
        // badge the entity's own site — e.g. openai.com for "openai".
        officialHost = Self.officialHost(for: q)
        // Pages you've already saved or visited that match the query — a purely local lookup,
        // shown as a compact module on the All tab. Skipped in private tabs so a private SERP
        // never surfaces your normal-mode library.
        libraryMatches = isPrivate ? [] : LibraryStore.shared.suggestions(for: q, limit: 2)
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

    // MARK: - News controls (time filter + sort)

    /// SearXNG `time_range` for the News scope: nil = any time; "day" / "week" / "month" / "year".
    private(set) var newsTimeRange: String?
    /// Latest (true) presents the news SERP purely by publish time; Top (false) keeps ranked order.
    var newsSortByRecency = false

    func setNewsTimeRange(_ range: String?) {
        guard range != newsTimeRange else { return }
        newsTimeRange = range
        if scope == .news, !searchQuery.isEmpty { runSearch(searchQuery, scope: .news) }
    }

    /// The current query's official-site host from the offline entity DB (nil for non-entity
    /// queries). Rows on this host (or its subdomains) carry an "Official site" seal.
    private(set) var officialHost: String?

    /// Bookmark/history hits for the current query ("From your library" on the All tab).
    private(set) var libraryMatches: [Suggestion] = []

    /// Selection handed off from the edit menu's "Explain This" — the shell opens the page chat
    /// seeded with it, then clears the field.
    var pendingSelectionExplain: String?
    /// Selection for "Translate This" — the shell shows the system translation popover.
    var pendingSelectionTranslation: String?

    /// Whether `host` is the query entity's own site.
    func isOfficialHost(_ host: String) -> Bool {
        guard let official = officialHost, !official.isEmpty else { return false }
        let h = host.lowercased()
        return h == official || h.hasSuffix(".\(official)")
    }

    /// The entity's site host, normalized (lowercased, no `www.`): its declared authority host,
    /// else the host of its primary URL.
    private static func officialHost(for query: String) -> String? {
        guard let entity = EntityQueryMatcher.bestEntity(for: query) else { return nil }
        let raw = entity.authorityHost ?? URL(string: entity.primaryURL)?.host
        guard var host = raw?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The news rows in display order. Sorting reads the primed `newsPublishedDate`, so Latest is
    /// a pure re-order — no re-fetch; dateless results sink to the end in their ranked order.
    var newsDisplayResults: [SearXNGResult] {
        guard scope == .news, newsSortByRecency else { return results }
        return results.enumerated().sorted { a, b in
            switch (a.element.newsPublishedDate, b.element.newsPublishedDate) {
            case let (da?, db?): return da > db
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
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

    /// How many consecutive empty/duplicate pages we tolerate before stopping pagination.
    private static let maxEmptyPages = 3
    /// Hard ceiling so a broken instance can't loop forever.
    private static let maxPage = 40

    /// Session SERP cache: raw hits + suggestions keyed by query/scope/page/settings. Makes scope
    /// flips, re-searches, and back-to-results instant, and lets a background prefetch of page 2
    /// turn infinite scroll into a cache hit.
    private static var serpCache: [String: (hits: [SearXNGResult], suggestions: [String], at: Date)] = [:]
    private static let serpCacheTTL: TimeInterval = 8 * 60
    private static let serpCacheCap = 30

    private static func cacheKey(_ q: String, _ categories: String, _ page: Int, _ timeRange: String?) -> String {
        let s = SearchSettings.shared
        return "\(q.lowercased())|\(categories)|\(page)|\(s.safeSearch.rawValue)|\(s.resolvedContentLanguage)|\(timeRange ?? "any")"
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
    private static func fetchHits(_ q: String, categories: String, page: Int,
                                  timeRange: String? = nil) async throws -> (hits: [SearXNGResult], suggestions: [String]) {
        let key = cacheKey(q, categories, page, timeRange)
        if let cached = cached(key) { return cached }
        let s = SearchSettings.shared
        // Always send a concrete language (auto → system/app — any locale, not a short list).
        let language = s.resolvedContentLanguage

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
                    safeSearch: s.safeSearch.rawValue, language: language, pageNo: page,
                    timeRange: timeRange
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
        // Always clear the load-more spinner on every exit path (including cancel) so a cancelled
        // task can never leave the SERP stuck with isLoadingMore == true (which blocks further pages).
        defer {
            if !reset { isLoadingMore = false }
        }

        if reset {
            do {
                let (hits, suggestions) = try await Self.fetchHits(
                    searchQuery, categories: scope.categories, page: 1,
                    timeRange: scope == .news ? newsTimeRange : nil
                )
                if Task.isCancelled { return }
                let processed = SearchResultProcessor.process(
                    raw: hits,
                    existing: [],
                    query: searchQuery,
                    category: scope.categories,
                    append: false
                )
                results = processed
                searchSuggestions = suggestions
                searchPhase = processed.isEmpty
                    ? .failed(String(format: L("No results for “%@”."), searchQuery))
                    : .loaded
                pageNo = 1
                canLoadMore = !hits.isEmpty && !processed.isEmpty
                if canLoadMore {
                    let q = searchQuery, cats = scope.categories
                    let range = scope == .news ? newsTimeRange : nil
                    Task.detached(priority: .utility) {
                        _ = try? await BrowserModel.fetchHits(q, categories: cats, page: 2, timeRange: range)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? L("Search failed. Check your connection, or the instance in Settings.")
                searchPhase = .failed(msg)
                canLoadMore = false
            }
            return
        }

        // Pagination: keep requesting the next page until we actually append new results or the
        // instance is exhausted. Instances often re-return near-duplicates across pageno — the
        // processor then dedupes them to zero new rows, which used to leave infinite scroll dead
        // because List row onAppear had already fired and wouldn't re-fire.
        var page = pageNo + 1
        var emptyStreak = 0
        do {
            while page <= Self.maxPage {
                let (hits, _) = try await Self.fetchHits(
                    searchQuery, categories: scope.categories, page: page,
                    timeRange: scope == .news ? newsTimeRange : nil
                )
                if Task.isCancelled { return }

                if hits.isEmpty {
                    pageNo = page
                    canLoadMore = false
                    return
                }

                let before = results.count
                let processed = SearchResultProcessor.process(
                    raw: hits,
                    existing: results,
                    query: searchQuery,
                    category: scope.categories,
                    append: true
                )
                results = processed
                pageNo = page

                let gained = processed.count - before
                if gained > 0 {
                    canLoadMore = true
                    // Warm the next page so the next scroll is a cache hit.
                    let q = searchQuery, cats = scope.categories, next = page + 1
                    let range = scope == .news ? newsTimeRange : nil
                    Task.detached(priority: .utility) {
                        _ = try? await BrowserModel.fetchHits(q, categories: cats, page: next, timeRange: range)
                    }
                    return
                }

                // Raw hits came back but everything was a duplicate / filtered out — skip ahead.
                emptyStreak += 1
                if emptyStreak >= Self.maxEmptyPages {
                    canLoadMore = false
                    return
                }
                page += 1
            }
            canLoadMore = false
        } catch {
            if Task.isCancelled { return }
            // Keep canLoadMore true so the user can try again by scrolling; only hard-stop on empty.
            canLoadMore = true
        }
    }

    // MARK: - Tab snapshot (Safari-style grid card)

    /// Captures the web view's current look for the tab grid. Called when a page finishes loading
    /// and when the user leaves the tab / opens the switcher.
    func captureSnapshot() {
        guard content == .web, webView.bounds.width > 0, !isLoading else { return }
        // Capped width: the grid card is ~180 pt and the swipe preview is transient, so a full
        // 3x-screen capture (~12 MB per tab) was pure memory tax — this is ~1/3 the bytes and
        // still crisp everywhere the snapshot is shown.
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 700)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
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

    // MARK: - Picture in Picture

    /// Puts the page's main video into Picture in Picture (or brings it back inline).
    /// Returns false when the page has no video or WebKit declined — the caller tells the user
    /// rather than leaving a menu item that silently does nothing.
    @discardableResult
    func togglePictureInPicture() async -> Bool {
        guard content == .web else { return false }
        let result = try? await webView.evaluateJavaScript(MediaPlayback.pictureInPictureJS)
        let mode = result as? String
        return mode == "picture-in-picture" || mode == "inline"
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
        WebsiteDarkMode.apply(to: config)
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

    /// Batches tracker tallies so the page-info / chrome badge isn't rewritten every message.
    @ObservationIgnored private var pendingBlockedDelta = 0
    @ObservationIgnored private var pendingBlockedDomains: [String] = []
    @ObservationIgnored private var blockedFlushTask: Task<Void, Never>?

    func recordBlockedTrackers(_ n: Int, domains: [String]) {
        guard n > 0, !shieldsLoweredForPage else { return }
        pendingBlockedDelta += n
        if pendingBlockedDomains.count < 40 {
            pendingBlockedDomains.append(contentsOf: domains.prefix(20 - pendingBlockedDomains.count))
        }
        // Publish UI count at a gentle cadence; lifetime stats go through ShieldSettings (also coalesced).
        if blockedFlushTask == nil {
            blockedFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard let self, !Task.isCancelled else { return }
                self.flushBlockedTrackers()
            }
        }
    }

    private func flushBlockedTrackers() {
        blockedFlushTask = nil
        let n = pendingBlockedDelta
        let domains = pendingBlockedDomains
        pendingBlockedDelta = 0
        pendingBlockedDomains = []
        guard n > 0 else { return }
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

    /// The tab's full session (back/forward list + scroll position), captured before it parks on
    /// about:blank. Restoring this instead of re-issuing a GET is what keeps hibernation invisible:
    /// a bare `load(url)` starts a brand-new navigation, which loses the back stack and re-fetches
    /// the page from scratch — and a URL the user reached through the site (a client-side route, a
    /// POST result, a one-time link) is not always independently GET-able, so the reload can land on
    /// the site's own 404. Session restore replays the history entry the tab already had.
    @ObservationIgnored private var hibernatedState: Any?

    /// Under memory pressure, background tabs park on about:blank (snapshot already captured for
    /// the grid) and restore their session when re-activated.
    func hibernate() {
        guard content == .web, !isLoading, hibernatedURL == nil,
              let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        captureSnapshot()
        hibernatedURL = url
        hibernatedState = webView.interactionState
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func reviveIfNeeded() {
        guard let url = hibernatedURL else { return }
        hibernatedURL = nil
        // Restoring interactionState also REPLACES the back-forward list, which is what discards the
        // about:blank placeholder the parking load pushed onto it. Without this the first Back after
        // a hibernated tab wakes up lands the user on a blank page.
        if let state = hibernatedState {
            hibernatedState = nil
            content = .web
            loadError = nil
            webView.interactionState = state
            return
        }
        load(url)  // parkForRestore path: a session restored from disk has a URL but no live state
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
                MainActor.assumeIsolated {
                    // Throttle: estimatedProgress fires many times per load; sub-2% steps only
                    // thrash the progress bar view without reading better. Always publish 0 and 1.
                    guard let self else { return }
                    let p = wv.estimatedProgress
                    if p >= 1.0 || p <= 0.02 || abs(p - self.progress) >= 0.02 {
                        self.progress = p
                    }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = wv.isLoading
                    if !wv.isLoading {
                        self?.progress = 1
                        self?.refreshControl.endRefreshing()
                        // Favicon capture is allowed ONLY here — for the page actually being
                        // visited (see FaviconStore's privacy rule). Private tabs leave no trace.
                        if self?.isPrivate == false { FaviconStore.shared.captureIfNeeded(from: wv) }
                        self?.captureSnapshot()
                        // Force chrome lift re-apply after DOM settles (reset cache so late banners lift).
                        self?.lastChromeLiftPoints = -1
                        self?.applyBottomInset()
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
                    let title = wv.title ?? ""
                    // Skip no-op title churn (SPAs rewrite the title constantly).
                    guard title != self.pageTitle else { return }
                    self.pageTitle = title
                    if !self.isPrivate, SearchSettings.shared.saveHistory, let u = wv.url {
                        LibraryStore.shared.updateTitle(url: u.absoluteString, title: title)
                    }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.webCanGoBack = wv.canGoBack
                    self.webCanGoForward = wv.canGoForward
                    if let u = wv.url {
                        let s = u.absoluteString
                        guard s != self.urlText else { return }
                        self.urlText = s
                        // New document → allow chrome-lift CSS to re-inject for this page.
                        self.lastChromeLiftPoints = -1
                        if !self.isPrivate, SearchSettings.shared.saveHistory {
                            LibraryStore.shared.recordVisit(url: s, title: self.pageTitle)
                        }
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webCanGoBack != wv.canGoBack else { return }
                    self.webCanGoBack = wv.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webCanGoForward != wv.canGoForward else { return }
                    self.webCanGoForward = wv.canGoForward
                }
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
        // Titles resolve here (main actor) so the action-provider closure only captures strings.
        let titles = (newTab: L("Open in New Tab"), privateTab: L("Open in Private Tab"),
                      copy: L("Copy Link"), share: L("Share…"))
        // webView is captured weakly ONCE at the provider level (the Share action below needs
        // it as a presentation anchor; a strong capture here would be redeclared-ownership noise).
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak webView] _ in
            var actions: [UIAction] = [
                UIAction(title: titles.newTab, image: UIImage(systemName: "plus.square.on.square")) { _ in
                    model?.onOpenInNewTab?(url)
                },
                UIAction(title: titles.privateTab, image: UIImage(systemName: "hand.raised")) { _ in
                    model?.onOpenInNewPrivateTab?(url)
                },
                UIAction(title: titles.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = url.absoluteString
                },
            ]
            actions.append(
                UIAction(title: titles.share, image: UIImage(systemName: "square.and.arrow.up")) { _ in
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
