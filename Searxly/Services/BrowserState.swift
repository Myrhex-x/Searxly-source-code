//
//  BrowserState.swift
//  Searxly
//
//  Extracted from the monster ContentView.swift during the 2026 refactor.
//  Central @Observable owner for browser UI state, search, tabs, persistence coordination,
//  and action methods. ContentView is now a thin layout/orchestration layer.
//  Created as a new file (per guidance to prevent bugs in monolithic views).
//  Follows patterns from LocalSearxngManager, PrivacyManager, WireGuardManager, etc.
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
    var isReaderMode = false
    var showingFindBar = false
    var findSearchTerm = ""

    // Reader sheet content (populated by extraction from toolbar or WebView callback)
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

    // MARK: - Address bar suggestions (local sites + remote search autocomplete)
    var suggestions: [AddressSuggestion] = []
    var suggestionsSelectedIndex: Int = 0
    var suggestionsIsLoading = false
    /// When true the dropdown stays hidden until the user types again (click-away, escape, search submit).
    var suggestionsPanelSuppressed = false

    var suggestionsRefreshTask: Task<Void, Never>?
    var suggestionsRequestGeneration: UInt = 0
    var hasHealedCrossedHistoryTitles = false

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
    var showingSettings = false   // also set from sidebar / badges
    var settingsInitialCategory: SettingsCategory = .appearance
    var showingWallet = false

    /// When true, the main content area shows a full-page history manager (all entries, delete, filter, etc.)
    /// instead of web content, search results, or home.
    var showingFullHistory = false

    // MARK: - Local AI (sheet + onboarding prompt; logic in SearchCoordinator)
    var showingLocalAIChat: Bool = false
    var showEnableAIToolsPrompt = false
    /// A pending "Ask Searxly AI" request from the page right-click menu (selection → chat seed).
    /// Consumed by the chat sheet when it appears (or live, if already open).
    var pendingAIChatSeed: AIChatSeed? = nil
    /// A pending lightweight quick answer (Explain / Summarize) shown in the Siri-style popup.
    var quickAnswer: QuickAnswerRequest? = nil

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

        // Listen for "Ask Searxly AI" picks from the page right-click menu (SearxlyWebView).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAskAISelectionNote(_:)),
            name: .searxlyAskAISelection,
            object: nil
        )
    }

    @objc func handleAskAISelectionNote(_ note: Notification) {
        let text = (note.userInfo?["text"] as? String) ?? ""
        let actionRaw = (note.userInfo?["action"] as? String) ?? AIChatSeed.Action.ask.rawValue
        let title = (note.userInfo?["title"] as? String) ?? ""
        let url = (note.userInfo?["url"] as? String) ?? ""
        DispatchQueue.main.async { [weak self] in
            self?.handleAskAISelection(text: text, actionRaw: actionRaw, title: title, url: url)
        }
    }

    /// Routes a page-menu request: "Ask" opens the full chat; "Explain"/"Summarize"/"Summarize page"
    /// use the lightweight Siri-style quick-answer popup instead.
    func handleAskAISelection(text: String, actionRaw: String, title: String = "", url: String = "") {
        let action = AIChatSeed.Action(rawValue: actionRaw) ?? .ask
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // PRIVACY: never ship Private-tab page content to the cloud backend. Show a notice instead.
        let prefs = LocalIntelligenceManager.shared.preferences
        let cloudActive = prefs.searxlyAIEnabled && prefs.useSearxlyAI
        if (selectedTab?.isPrivate ?? false) && cloudActive {
            quickAnswer = QuickAnswerRequest(
                selection: "",
                action: action,
                staticNotice: "Searxly AI Cloud is paused in Private tabs so your private browsing never leaves your Mac. Switch to on‑device AI in Settings, or use a normal tab."
            )
            return
        }

        switch action {
        case .ask:
            guard !trimmed.isEmpty else { return }
            pendingAIChatSeed = AIChatSeed(selection: String(trimmed.prefix(4000)), action: .ask)
            openLocalAIChat()
        case .explain, .summarize:
            guard !trimmed.isEmpty else { return }
            quickAnswer = QuickAnswerRequest(selection: String(trimmed.prefix(4000)), action: action)
            LocalIntelligenceManager.shared.warmUpIfNeeded()
        case .summarizePage:
            // Page text is untrusted + can be large; PageContentGuard sanitizes/caps before the model.
            quickAnswer = QuickAnswerRequest(
                selection: String(trimmed.prefix(16000)),
                action: .summarizePage,
                pageTitle: title.isEmpty ? nil : title,
                pageURL: url.isEmpty ? nil : url
            )
            LocalIntelligenceManager.shared.warmUpIfNeeded()
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
        NotificationCenter.default.removeObserver(self, name: .searxlyAskAISelection, object: nil)
    }
}

// Passwords vault special tab notification (preserved non-crypto feature).
extension Notification.Name {
    static let showPasswordsVaultTabRequested = Notification.Name("Searxly.ShowPasswordsVaultTabRequested")
}
