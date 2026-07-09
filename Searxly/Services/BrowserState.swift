//
//  BrowserState.swift
//  Searxly
//
//  Extracted from the monster ContentView.swift during the 2026 refactor.
//  Central @Observable owner for browser UI state, search, tabs, persistence coordination,
//  and action methods. ContentView is now a thin layout/orchestration layer.
//  Created as a new file (per guidance to prevent bugs in monolithic views).
//  Follows patterns from LocalSearxngManager, PrivacyManager, SystemVPNManager, etc.
//

import Foundation
import SwiftUI
import WebKit

@Observable
@MainActor
final class BrowserState {
    // MARK: - Search state (Phase 3)
    var searchText = ""
    var searchResults: [SearXNGResult] = []
    var isLoadingSearch = false
    var searchErrorMessage: String?
    var currentSearchCategory: String? = nil
    var lastSearchQuery: String = ""
    var lastEffectiveSearchQuery: String = ""
    var selectedImageForPreview: SearXNGResult? = nil

    // MARK: - News SERP controls (news category only)
    /// SearXNG `time_range` for the news tab: nil (any time), "day", "week", "month", or "year".
    /// A server-side refetch — bing_news honours it; freshness-first sources return their latest set.
    var newsTimeRange: String? = nil
    /// Latest-first (by parsed publish time) vs. Top (relevance). A pure view-layer sort over the
    /// same results, so toggling is instant and doesn't refetch or lose scroll position.
    var newsSortByRecency: Bool = false
    /// When the on-screen news results were last fetched — drives the "Updated Xm ago" affordance.
    var newsLastRefreshed: Date? = nil

    /// Fresh news fetched in parallel during an "All" search, used to inject a Google-style "Top
    /// stories" module into the general results. Empty unless the current All query has recent news.
    var allTabNewsResults: [SearXNGResult] = []
    /// The in-flight parallel news fetch for the All tab (cancelled when the query/category changes).
    var allTabNewsTask: Task<Void, Never>? = nil

    /// Live auto-refresh (news + Latest only): stories found by background polling that are newer than
    /// what's on screen, held here until the user taps the "N new stories" pill to merge them in — we
    /// never yank content out from under a reader.
    var pendingNewsStories: [SearXNGResult] = []
    /// The recurring background poll task; runs only while the news tab is in Latest mode.
    var newsAutoRefreshTask: Task<Void, Never>? = nil

    // Pagination (infinite scroll for images/videos + optional web load-more)
    var searchPageNo: Int = 1
    var isLoadingMoreResults: Bool = false
    var canLoadMoreResults: Bool = true
    /// Consecutive load-more pages that added nothing new. Aggregated SearXNG engines are flaky
    /// (a single request can be CAPTCHA'd/rate-limited and come back empty), so we tolerate a few
    /// dry pages before giving up instead of freezing scroll on the first one.
    var consecutiveEmptyLoadMorePages: Int = 0

    /// The base URL of the SearXNG instance that successfully served the current `searchResults`.
    /// Used to construct reliable /image_proxy URLs for the images & videos grids + preview sheet
    /// (instead of blindly using .first, which is wrong after fallback or with multiple instances).
    var lastSearchInstanceURL: String? = nil

    /// Right-column SERP knowledge panel (entity / dictionary), resolved via private SearXNG only.
    var knowledgePanelState: KnowledgePanelDisplayState = .hidden
    var knowledgePanelEnabled: Bool = Persistence.knowledgePanelEnabled()
    var knowledgePanelTask: Task<Void, Never>?
    /// Result of the in-flight panel resolution, which runs in parallel with the search fetch and may
    /// finish before it. Held here until both the resolution and the search settle, then committed to
    /// `knowledgePanelState` (gated on the search actually returning results). See SearchCoordinator.
    var knowledgePanelResolved: (query: String, content: KnowledgePanelContent?)?

    /// Top-of-results SERP "local pack" for place queries (e.g. "pharmacie perpignan") — OpenStreetMap
    /// places + a live map, resolved via the Searxly gateway. Mirrors the knowledge-panel lifecycle:
    /// resolves in parallel with the search and commits once both settle (see SearchCoordinator).
    var localPackState: LocalPackDisplayState = .hidden
    var localPackEnabled: Bool = Persistence.localPackEnabled()
    var localPackTask: Task<Void, Never>?
    var localPackResolved: (query: String, data: LocalPackData?)?
    /// The place query detected for the current search (drives the opt-in prompt when the feature is off).
    var localPackDetected: LocalPackQuery?
    /// Set when the user dismisses the opt-in prompt — suppresses further prompts for the rest of the session.
    var localPackPromptDismissed = false

    // Transient highlight for AI citations (or future "jump to result" actions).
    // The SearchResultCard observes this (via passed isHighlighted) to give a temporary emphasis
    // on the flat row without any heavy chrome. Auto-cleared by the highlighter.
    var highlightedResultURL: String? = nil

    // MARK: - Web / Browser state (Phases 4-7, multi-tab aware)
    // Note: Per-tab webViews live in BrowserTab. These drive the active WebViewRepresentable bindings.
    var isWebLoading = false
    var webProgress: Double = 0.0
    var webPageTitle: String = ""
    var webCurrentURL: URL? = nil
    var showingWebContent = false

    /// A detected `.onion` mirror for the page in the current normal tab (Onion-Location). The banner
    /// only shows while this offer's host still matches the page on screen (see activeOnionLocationOffer).
    var onionLocationOffer: OnionLocationOffer?

    /// First-run Tor consent gate: drives the one-time disclosure sheet shown before the user's first
    /// onion connection. `pendingOnionURL` is the address to open once they acknowledge.
    var showTorDisclosure = false
    var pendingOnionURL: URL?

    // Reader / Find (minimally wired; passed through to representable)
    var webViewCanGoBack = false
    var webViewCanGoForward = false
    /// Bumped when the per-tab native navigation stack changes so toolbar buttons refresh.
    var navigationHistoryRevision = 0

    var canGoBack: Bool {
        _ = navigationHistoryRevision
        guard let tab = selectedTab, tab.kind == .web else { return false }
        if showingWebContent {
            return webViewCanGoBack || tab.navigationHistory.canGoBack
        }
        return tab.navigationHistory.canGoBack
    }

    var canGoForward: Bool {
        _ = navigationHistoryRevision
        guard let tab = selectedTab, tab.kind == .web else { return false }
        if showingWebContent {
            return webViewCanGoForward || tab.navigationHistory.canGoForward
        }
        return tab.navigationHistory.canGoForward
    }
    var showingFindBar = false
    var findSearchTerm = ""

    // Reader mode (distraction-free view of the current page's extracted article).
    var isReaderMode = false
    var readerTitle: String = ""
    var readerHTML: String = ""
    var showingReaderSheet: Bool = false

    // MARK: - Tabs (Phase 6)
    // Initial tab is a normal web tab.
    var tabs: [BrowserTab] = [BrowserTab()]
    var selectedTabID: UUID? = nil

    /// Snapshots of recently closed tabs (most recent first, capped at 15).
    /// Not persisted — session-only, cleared on quit.
    var recentlyClosedSnapshots: [TabSnapshot] = []

    // Sidebar (current only layout)
    // Toggled between narrow rail and expanded list via chevron. No free drag-to-resize (removed).
    // Width is always one of the two canonical values. lastExpandedSidebarWidth is used by toggle
    // to remember a comfortable expanded size across collapses.
    var isSidebarCollapsed = false
    var currentSpace: Space = .personal

    // Canonical sizes (used for toggle + density switch in the view).
    static let railWidth: CGFloat = 72
    static let defaultExpandedWidth: CGFloat = 260
    static let collapseThreshold: CGFloat = 115

    var sidebarWidth: CGFloat = 260
    var lastExpandedSidebarWidth: CGFloat = 260

    let sidebarWidthKey = "Searxly.SidebarWidth"
    let lastExpandedSidebarWidthKey = "Searxly.LastExpandedSidebarWidth"

    // MARK: - Persisted data (Phase 7+)
    var history: [HistoryItem] = []
    var bookmarks: [BookmarkItem] = []

    /// User-created sidebar categories for organizing tabs (see TabCategory). Capped at
    /// `maxCustomCategories`. Persisted in AppData; per-tab membership lives on BrowserTab.categoryID.
    var customTabCategories: [TabCategory] = []

    /// Maximum number of custom sidebar categories a user can create (on top of the built-in
    /// PINNED / TABS / UTILITIES / TOR groups).
    nonisolated static let maxCustomCategories = 3

    // MARK: - Address bar suggestions (local sites + remote search autocomplete)
    var suggestions: [AddressSuggestion] = []
    var suggestionsSelectedIndex: Int = 0
    var suggestionsIsLoading = false
    /// When true the dropdown stays hidden until the user types again (click-away, escape, search submit).
    var suggestionsPanelSuppressed = false

    var suggestionsRefreshTask: Task<Void, Never>?
    var suggestionsRequestGeneration: UInt = 0
    var hasHealedCrossedHistoryTitles = false

    /// Whether the address bar currently has keyboard focus. Mirrors ContentView's @FocusState so the
    /// suggestions panel's lifecycle (incl. the blur grace period that lets a suggestion click land) can
    /// live in this @Observable model rather than being torn down the instant focus is lost.
    var addressBarFocused = false
    /// Pending "dismiss suggestions shortly after blur" work, cancelled if focus returns.
    var suggestionBlurDismissTask: Task<Void, Never>?

    /// Whether the suggestions dropdown should render (respects user dismiss + loading state).
    var shouldShowSuggestionsPanel: Bool {
        !suggestionsPanelSuppressed && (!suggestions.isEmpty || suggestionsIsLoading)
    }

    // Notification bridge so WebView KVO (in any coordinator) can push an atomic (url,title)
    // snapshot for history repair without needing a direct BrowserState reference in the representable.
    // Marked nonisolated so it can be referenced from Coordinator (non-actor) code in WebViewRepresentable
    // and from deinit, even though BrowserState is @MainActor. Notification.Name is just a Sendable string wrapper.
    nonisolated static let historyTitleSnapshotNotification = Notification.Name("Searxly.historyTitleSnapshot")

    // Sheet flags (presented by ContentView, mutated from many places)
    var showingBookmarks = false
    var showingDownloads = false
    var showingKeyboardShortcuts = false
    var showingClearData = false
    /// Destructive confirmation for the Panic Wipe menu command (⌘⌥⇧⌫). The actual wipe
    /// runs in performPanicWipe() once the user confirms.
    var showingPanicWipeConfirm = false
    var showingSettings = false   // also set from sidebar / badges
    var settingsInitialCategory: SettingsCategory = .appearance
    var showingWallet = false

    /// Spotlight-style command palette (⌘K): fuzzy quick-jump across open tabs, bookmarks, history,
    /// plus quick actions. Presented as a centered floating overlay in ContentView.
    var showingCommandPalette = false

    /// "Import data from other browsers" hub sheet (bookmarks HTML / passwords CSV).
    var showingImportData = false

    /// When true, the main content area shows a full-page history manager (all entries, delete, filter, etc.)
    /// instead of web content, search results, or home.
    var showingFullHistory = false

    // MARK: - Instances (Phase 8)
    var searxInstances: [SearXNGInstance] = SearXNGInstance.defaultInstances
    var currentInstanceID: UUID = UUID()

    // MARK: - Onboarding
    // Note: hasCompletedOnboarding remains @AppStorage in ContentView for now (passed down).
    // State forces false here when no instances on load.

    // MARK: - Session (Phase 13)
    let sessionKey = "Searxly.LastSessionURLs"

    // MARK: - Computed (used for layout, display, active web)
    var selectedTab: BrowserTab? {
        if let id = selectedTabID {
            return tabs.first { $0.id == id }
        }
        return tabs.first
    }

    // MARK: - Password Vault (always-on privacy feature)

    var isPasswordsVaultSelected: Bool {
        selectedTab?.kind == .passwords
    }

    private var fallbackWebView = WKWebView()

    var activeWebView: WKWebView {
        selectedTab?.webView ?? fallbackWebView   // fallback (legacy single path rarely hit)
    }

    var currentSearxInstance: SearXNGInstance {
        searxInstances.first { $0.id == currentInstanceID }
            ?? searxInstances.first
            ?? SearXNGInstance(name: "Not configured", url: "")
    }

    var currentInstanceDisplay: String {
        guard !searxInstances.isEmpty else { return "Setup required" }
        let inst = currentSearxInstance
        let name = inst.name
        let isLikelyPublic = SearXNGInstance.isPublicInstance(url: inst.url)
        return isLikelyPublic ? name : "Private: \(name)"
    }

    var isPureHomeState: Bool {
        !showingWebContent && searchResults.isEmpty && searchErrorMessage == nil && !isLoadingSearch
    }

    /// True when the home hero should show the orange "instance not detected" affordance.
    var shouldShowHomeInstanceWarning: Bool {
        if searxInstances.isEmpty { return true }
        let url = currentSearxInstance.url.lowercased()
        let isLocalInstance = url.contains("localhost") || url.contains("127.0.0.1")
        guard isLocalInstance else { return false }
        switch LocalSearxngManager.shared.status {
        case .running, .starting:
            return false
        default:
            return true
        }
    }

    /// Best-effort domain of the currently selected web tab (for password vault "save current" flows).
    var currentWebDomain: String? {
        guard let tab = selectedTab, tab.kind == .web else { return nil }
        return tab.currentURL?.host?.lowercased()
    }

    // Lightweight page context for the password pill (no full autofill).
    // Lets the in-browser pill know when the current page has password fields
    // and whether it looks like a "create new password" / signup flow.
    var currentPageHasPasswordField: Bool = false
    var currentPageIsLikelyPasswordCreation: Bool = false

    /// Debounced domain for password-save offer notifications (see TabCoordinator).
    var lastOfferedSaveDomain: String = ""

    /// Guards NotificationCenter registration in `loadPersistedData` (also called after backup restore).
    var historyTitleObserverRegistered = false

    // Password vault web-page actions live in TabCoordinator.swift.

    // These are derived in ContentView from @AppStorage reduceLiquidGlass.
    // State provides them once glassEnabled/toolbarMaterial are passed in (no ownership here).
    // ContentView computes and passes down for all subviews (existing pattern).

    // MARK: - Init / Load
    init() {
        // Load will be called explicitly from ContentView.onAppear (mirrors old behavior)
        // so that @AppStorage values are available before we force onboarding etc.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppPrivacyModeChanged),
            name: PrivacyManager.appPrivacyModeChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMaxProtectionChanged),
            name: PrivacyManager.maxProtectionChangedNotification,
            object: nil
        )
    }

    /// App privacy mode changed (e.g. into/out of Maximum Privacy). Per-mode webview configuration —
    /// Tor SOCKS routing and the Strict fingerprint cluster — is decided at creation in WebViewFactory,
    /// so existing tabs must be rebuilt to pick it up. Reuse the sanctioned hibernate→wakeUp recreate
    /// path: tear every web tab down, then wake the visible one (background tabs wake on next selection
    /// via TabCoordinator). The kill switch already guards navigations in the meantime.
    /// The last app-privacy mode we reacted to — lets us detect the TRANSITION *into* Maximum (which
    /// closes all tabs) versus any other mode change (rebuild only). Seeded to the current mode so a
    /// launch already-in-Maximum doesn't nuke a restored session.
    private var lastReactedPrivacyMode: AppPrivacyMode = PrivacyManager.shared.appPrivacyMode

    @objc func handleAppPrivacyModeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let mode = PrivacyManager.shared.appPrivacyMode
            let enteringMaximum = (mode == .maximum && self.lastReactedPrivacyMode != .maximum)
            self.lastReactedPrivacyMode = mode

            if enteringMaximum {
                // Entering Maximum Privacy starts from a clean slate: close every current tab and open
                // one fresh tab. Reloading old tabs isn't enough — the strict fingerprint farbling +
                // WebRTC IP-leak block only apply to tabs created AFTER the mode engages, and this also
                // drops whatever you were viewing under your real IP out of the session.
                self.closeAllTabs()
            } else {
                // Any other change (leaving Maximum, normal↔encrypted): rebuild open web tabs so the
                // strict hardening is added/removed correctly, without discarding them.
                for tab in self.tabs where tab.kind == .web {
                    tab.hibernate()
                }
                self.selectedTab?.wakeUp()
            }
        }
    }

    /// The protection network (Tor vs VPN) inside Maximum Privacy changed.
    /// Web routing config (per-tab SOCKS for Tor mode vs none for VPN) is baked at WebView creation,
    /// so rebuild tabs so the correct proxy / hardening applies. No-op if not currently in Maximum.
    @objc func handleMaxProtectionChanged() {
        guard PrivacyManager.shared.appPrivacyMode == .maximum else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in self.tabs where tab.kind == .web {
                tab.hibernate()
            }
            self.selectedTab?.wakeUp()
        }
    }

    @objc func handleHistoryTitleSnapshot(_ note: Notification) {
        guard let url = note.userInfo?["url"] as? URL,
              let title = note.userInfo?["title"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            self?.updateHistoryTitleSnapshot(url: url, title: title)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: Self.historyTitleSnapshotNotification, object: nil)
    }
}

// Passwords vault special tab notification (preserved non-crypto feature).
extension Notification.Name {
    static let showPasswordsVaultTabRequested = Notification.Name("Searxly.ShowPasswordsVaultTabRequested")
    /// Opens the full-page Extensions marketplace (TabKind.extensions).
    static let showExtensionsTabRequested = Notification.Name("Searxly.ShowExtensionsTabRequested")
    /// Posted by the navigation delegate when a normal page advertises an `Onion-Location` mirror.
    /// userInfo: ["onion": <onion URL string>, "host": <page host>].
    static let onionLocationDetected = Notification.Name("Searxly.OnionLocationDetected")
    /// Posted when an onion tab fails to load — the onion host is then suppressed from future offers.
    /// userInfo: ["host": <onion host>].
    static let onionUnreachable = Notification.Name("Searxly.OnionUnreachable")
    /// Posted when Tor is switched off — open onion tabs reload to a "Tor is off" page.
    static let torDisabled = Notification.Name("Searxly.TorDisabled")
}

/// A detected `.onion` mirror offer for the page currently shown in a normal tab.
struct OnionLocationOffer: Equatable {
    let pageHost: String
    let onionURL: URL
}
