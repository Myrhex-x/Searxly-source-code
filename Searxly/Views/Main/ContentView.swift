//
//  ContentView.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//
//  REFACTORED: Monster view extraction complete. Most @State, logic methods (performSearchOrLoadInWebKit,
//  loadInWebView, tab mgmt, persistence, session), and inline sheets/row helpers moved to BrowserState.
//  This file is now thin orchestration + sidebarLayout + mainContentArea + sheet wiring + overlays.
//  See BrowserState.swift and the new Settings/ subfolder for extracted pieces.
//  (SearchResultCard also extracted to Components/.)
//

import SwiftUI
import AppKit  // NSWorkspace, etc.
import WebKit  // WKWebView, navigation, progress, etc. for Phases 4-7

struct ContentView: View {
    @State private var searchText = ""
    @FocusState var isAddressBarFocused: Bool
    @State var slimAddressBarFrame: CGRect = .zero

    func dismissSuggestionsAndBlur() {
        browserState.dismissSuggestionsPanel()
        isAddressBarFocused = false
    }

    func updateSuggestionsFromFocus() {
        let trimmed = browserState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAddressBarFocused && !trimmed.isEmpty {
            browserState.scheduleSuggestionsRefresh(userInitiated: false)
        } else if !isAddressBarFocused {
            browserState.dismissSuggestionsPanel()
        }
    }

    func submitFromAddressBar() {
        browserState.submitAddressBar()
    }

    // Persisted accessibility preference from Phase 2
    @AppStorage("reduceLiquidGlass") var reduceLiquidGlass = false

    // New: User-chosen appearance (System / Light / Dark)
    @AppStorage("appearanceMode") var appearanceModeRaw: String = "system"
    @State var systemColorScheme = AppearanceResolver.systemColorScheme

    // Home background stars (grok.com style). Default on for the premium feel.
    @AppStorage("homeStarsEnabled") var homeStarsEnabled = true

    // Sidebar is no longer freely resizable by dragging (removed due to persistent lag/glitch/size issues).
    // Width is now only changed via the chevron toggle in the sidebar (binary rail vs expanded).
    // We keep a simple width value in BrowserState for the frame + density switch.

    var resolvedColorScheme: ColorScheme {
        AppearanceResolver.resolved(modeRaw: appearanceModeRaw, system: systemColorScheme)
    }

    func refreshSystemColorScheme() {
        systemColorScheme = AppearanceResolver.systemColorScheme
    }

    /// True when we are on the clean new-tab / home state (no web, no results list, no errors).
    /// Used to center the search bar in the middle of the home page and suppress the top chrome bar.
    /// Now delegates to BrowserState (refactor).
    var isPureHomeState: Bool {
        browserState.isPureHomeState
    }

    // Phase 3: Search state + media preview now owned by browserState (see @State browserState above).
    // Old @State removed in refactor to eliminate duplication and centralize logic.

    // Web/reader/find states now in browserState (KVO bindings and active tab drive them).
    // Legacy single webView @State removed.

    // Tabs + selected now in browserState (passed as $browserState.tabs etc to SidebarTabList).

    // Phase 13: Basic session restoration
    private let sessionKey = "Searxly.LastSessionURLs"

    // History/bookmarks/showing* flags now owned by browserState (synced on load/save).

    // Sidebar state (collapse, space) now in browserState.

    // Onboarding state (Phase 12-15)
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false

    // === REFACTORED: BrowserState owns the bulk of former @State + logic ===
    @State var browserState = BrowserState()
    @State var appLockManager = AppLockManager.shared
    @State var encryptionRecoveryManager = EncryptionRecoveryManager.shared
    @State var hasCompletedInitialLaunchLoad = false
    var passwordVault = PasswordVaultManager.shared

    // Web login save prompt from form detection
    @State var showingWebSaveLogin = false
    @State var webSaveDomain = ""
    @State var webSaveUsername = ""
    @State var webSavePassword = ""

    // selectedTab / activeWebView / current* + instances now come from browserState (see its computed + vars).
    // Duplicate local @State removed in desync bugfix. All sheets/overlays now bind directly to browserState.
    var toolbarMaterial: Material { reduceLiquidGlass ? .regularMaterial : .ultraThinMaterial }
    var glassEnabled: Bool { !reduceLiquidGlass }

    // premiumTabStrip + tabButton removed — horizontal top-bar layout is no longer supported.
    // Left sidebar is the only UI.

    // bookmarkRow / historyRow removed — now using the polished extracted BookmarksHistoryView
    // (wired in the bookmarksSheet below). Duplication eliminated in monster refactor.

    // All heavy methods (performSearchOrLoadInWebKit, loadInWebView, clearNativeSearch, selectSearchCategory,
    // newTab / closeTab, move/forget, sync, smartURL, session) now live in BrowserState.
    // These are thin forwarding wrappers so existing call sites (AddressBar onSubmit, Sidebar closures, result cards)
    // continue to work with minimal diff during the refactor.

    func syncAddressBarWithWebURL() { browserState.syncAddressBarWithWebURL() }

    func performSearchOrLoadInWebKit() {
        let wasFocused = isAddressBarFocused
        browserState.performSearchOrLoadInWebKit()
        // Best-effort: if the bar had focus (or we are leaving home), make sure the (new) bar instance gets focus
        // for follow-up queries. Complements the isPureHomeState onChange transfer.
        if wasFocused {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                isAddressBarFocused = true
            }
        }
    }

    func loadInWebView(_ url: URL) {
        browserState.loadInWebView(url)
    }

    func presentSaveLoginSheet() {
        webSaveDomain = browserState.currentWebDomain ?? ""
        browserState.extractCredentialsFromCurrentPage { username, password in
            webSaveUsername = username
            webSavePassword = password
            showingWebSaveLogin = true
        }
    }

    func clearNativeSearch() {
        browserState.clearNativeSearch()
        // After clearing results the hero (or slim) bar becomes the primary UI again — give it focus
        // so the user can type the next query without extra clicks (matches Safari "search again" flow).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            isAddressBarFocused = true
        }
    }

    func selectSearchCategory(_ category: String?) { browserState.selectSearchCategory(category) }

    func openSearchResultInNewTab(_ result: SearXNGResult) {
        browserState.openSearchResultInNewTab(result)
    }

    func enableAIToolsQuick() {
        LocalIntelligenceManager.shared.preferences.toolsEnabled = true
        LocalIntelligenceManager.shared.persistPreferences()
    }

    func newTab() { browserState.newTab() }
    func newPrivateTab() { browserState.newPrivateTab() }
    func closeTab(_ tab: BrowserTab) { browserState.closeTab(tab) }
    func closeAllTabs() { browserState.closeAllTabs() }

    func moveTab(from source: Int, to destination: Int) {
        browserState.moveTab(from: source, to: destination)
    }
    func forgetDomainInSidebar(_ host: String) { browserState.forgetDomainInSidebar(host) }

    // MARK: - Persistence (now delegated to BrowserState)

    func loadPersistedData() {
        // BrowserState does the heavy lifting (and forces onboarding via the binding when needed).
        // All instance/current ID state is now owned exclusively by browserState; sheets bind directly to it.
        browserState.loadPersistedData(hasCompletedOnboardingBinding: $hasCompletedOnboarding)
    }

    func saveAllData() {
        browserState.saveAllData()
    }

    // MARK: - Phase 13: Session Restoration (delegated)

    func restoreLastSession() {
        browserState.restoreLastSession()
        // Sync locals used for bindings
        // (In full refactor the sidebar etc would read $browserState.tabs directly)
    }

    /// Heavy launch work (decrypt AppData, restore tabs, start local SearXNG). Skipped while App Lock is
    /// showing so Touch ID can present immediately on cold start.
    func performInitialLaunchLoadIfNeeded() {
        guard !encryptionRecoveryManager.isRecoveryRequired else { return }
        guard !hasCompletedInitialLaunchLoad else { return }
        hasCompletedInitialLaunchLoad = true

        if browserState.selectedTabID == nil {
            browserState.selectedTabID = browserState.tabs.first?.id
        }
        loadPersistedData()
        restoreLastSession()
        NotificationManager.shared.isBrowserActive = browserState.showingWebContent

        if UserDefaults.standard.string(forKey: "tabLayout") != "sidebar" {
            UserDefaults.standard.set("sidebar", forKey: "tabLayout")
        }
    }

    func saveCurrentSession() {
        browserState.saveCurrentSession()
    }

    // topToolbar (legacy) removed in refactor.
    // @ViewBuilder private var topToolbar: some View { ... }  <-- deleted

    // (legacy topToolbar / horizontal toolbar orphaned code fully cleaned)

    // Extracted large conditional content tree. (refactor note: now uses browserState heavily)
    @ViewBuilder
    var mainContentArea: some View {
        Group {
            // Full-page history (new dedicated mode for managing all history entries with delete, filter, etc.)
            if browserState.showingFullHistory {
                fullHistoryContent
            } else if let selected = browserState.selectedTab, selected.kind == .passwords {
                PasswordVaultTabView(
                    tab: selected,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onFillLogin: { domain, username, password in
                        browserState.fillLoginForDomain(domain: domain, username: username, password: password)
                    },
                    onOpenSite: { domain in
                        if let url = URL(string: "https://\(domain)") {
                            browserState.loadInWebView(url)
                        }
                    }
                )
            } else if browserState.showingWebContent {
                // Web content (progress, find bar, WebView + reader) extracted to its own view.
                // Side-effect .onChange handlers that touched parent state remain here for now.
                WebContentView(
                    isWebLoading: browserState.isWebLoading,
                    webProgress: browserState.webProgress,
                    activeWebView: browserState.activeWebView,
                    webPageTitle: $browserState.webPageTitle,
                    webCurrentURL: $browserState.webCurrentURL,
                    webViewCanGoBack: $browserState.webViewCanGoBack,
                    webViewCanGoForward: $browserState.webViewCanGoForward,
                    isReaderMode: $browserState.isReaderMode,
                    onReaderContentExtracted: { title, html in
                        browserState.readerTitle = title
                        browserState.readerHTML = html
                        browserState.showingReaderSheet = !html.isEmpty
                        browserState.isReaderMode = !html.isEmpty
                    },
                    showingFindBar: $browserState.showingFindBar,
                    findSearchTerm: $browserState.findSearchTerm,
                    onPerformFind: { browserState.performFindInPage($0) },
                    onExitFind: { browserState.dismissFindInPage() }
                )
                .overlay(alignment: .top) {
                    if let offer = browserState.activeOnionLocationOffer {
                        OnionLocationBanner(
                            host: offer.pageHost,
                            onOpen: { browserState.acceptOnionLocationOffer() },
                            onDismiss: { browserState.dismissOnionLocationOffer() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: browserState.activeOnionLocationOffer)
                .onChange(of: browserState.webCurrentURL) { _, _ in
                    syncAddressBarWithWebURL()
                    if browserState.showingWebContent {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            browserState.checkForLoginFormAndOfferSave()
                        }
                    }
                }
                .onChange(of: browserState.webProgress) { _, progress in
                    if progress >= 1.0 && browserState.showingWebContent {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            browserState.checkForLoginFormAndOfferSave()
                        }
                    }
                }
                .onChange(of: browserState.showingWebContent) { _, newValue in
                    if !newValue {
                        browserState.webProgress = 0
                        browserState.currentPageHasPasswordField = false
                        browserState.currentPageIsLikelyPasswordCreation = false
                    }
                    NotificationManager.shared.isBrowserActive = newValue
                }
                .onChange(of: browserState.webPageTitle) { _, newTitle in
                    if browserState.showingWebContent, let u = browserState.webCurrentURL {
                        browserState.refineHistoryTitle(for: u, to: newTitle)
                    }
                    browserState.syncSelectedTabMetadataFromWeb()
                }
            } else if browserState.searxInstances.isEmpty {
                // Extracted small state view
                NoSearxInstancesView(onOpenSettings: { browserState.showingSettings = true })

            } else if browserState.isLoadingSearch {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text(Localization.string("searching_searxng")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if !browserState.searchResults.isEmpty {
                // 2026 SERP redesign: the full results surface (header + category pills "All / Web / Images / Videos / News"
                // + rewrite badge + actual rows/grids) is now owned exclusively by SearchResultsView.
                // Previously the parent's header + pills were left in place, causing the duplication.
                SearchResultsView(
                    results: browserState.searchResults,
                    currentCategory: browserState.currentSearchCategory,
                    lastSearchQuery: browserState.lastSearchQuery,
                    glassEnabled: glassEnabled,
                    proxyBaseURL: browserState.lastSearchInstanceURL ?? browserState.searxInstances.first?.url,
                    highlightedResultURL: browserState.highlightedResultURL,
                    onClear: { clearNativeSearch() },
                    onSelectCategory: { selectSearchCategory($0) },
                    onOpenPage: { result in
                        if let url = URL(string: result.url) {
                            browserState.searchText = result.url
                            loadInWebView(url)
                            clearNativeSearch()
                        }
                    },
                    onOpenInNewTab: { result in
                        openSearchResultInNewTab(result)
                    },
                    onPreviewMedia: { result in
                        browserState.selectedImageForPreview = result
                    },
                    onLoadMore: { browserState.loadMoreSearchResults() },
                    isLoadingMore: browserState.isLoadingMoreResults,
                    canLoadMore: browserState.canLoadMoreResults,
                    knowledgePanelState: browserState.knowledgePanelState,
                    onOpenKnowledgeURL: { urlString in
                        if let url = URL(string: urlString) {
                            browserState.searchText = urlString
                            loadInWebView(url)
                            clearNativeSearch()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)

            } else if let err = browserState.searchErrorMessage, !err.isEmpty, !browserState.isLoadingSearch {
                // Friendly empty / no-results illustration in the main content area (complements the
                // calm under-bar banner). Triggered for "No results found..." and similar post-search errors.
                // Keeps the experience in the results "mode" instead of falling through to the home hero.
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary.opacity(0.6))

                    VStack(spacing: 6) {
                        Text(Localization.string("no_results_title"))
                            .font(.title3.weight(.semibold))

                        if !browserState.lastSearchQuery.isEmpty {
                            Text("for “\(browserState.lastSearchQuery)”")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }

                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    // Quick affordances
                    HStack(spacing: 8) {
                        Button {
                            // Re-run the same query (useful after a transient issue or to refresh)
                            performSearchOrLoadInWebKit()
                        } label: {
                            Label(Localization.string("try_again"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            clearNativeSearch()
                        } label: {
                            Label(Localization.string("button_clear"), systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)

            } else {
                // Pure home / new-tab hero state is now extracted to its own file for maintainability.
                // See Views/Home/HomeView.swift
                HomeView(
                    glassEnabled: glassEnabled,
                    searchText: $browserState.searchText,
                    isAddressBarFocused: $isAddressBarFocused,
                    searchErrorMessage: browserState.searchErrorMessage,
                    showInstanceNotDetected: browserState.shouldShowHomeInstanceWarning,
                    showEnableAIToolsPrompt: browserState.showEnableAIToolsPrompt,
                    localAIChatEnabled: LocalIntelligenceManager.shared.preferences.masterEnabled && LocalIntelligenceManager.shared.preferences.chatEnabled,
                    browserState: browserState,
                    onSubmit: { submitFromAddressBar() },
                    onOpenSettings: { browserState.showingSettings = true },
                    onDismissError: { browserState.searchErrorMessage = nil },
                    onEnableAITools: {
                        enableAIToolsQuick()
                        browserState.showEnableAIToolsPrompt = false
                    },
                    onLaterAITools: {
                        browserState.showEnableAIToolsPrompt = false
                    },
                    onOpenLocalAIChat: {
                        browserState.openLocalAIChat()
                    }
                )
            }
        }
    }

    var body: some View {
        bodyContent
    }

    // Final extraction layer.
    // We deliberately build the long modifier chain using distinct sub-expressions
    // (separate computed properties) to keep the type checker happy.
    // Each property below is a reasonably sized expression.
    var bodyContent: some View {
        baseWithSheetsAndEvents
            .onKeyPress(.return) {
                if isAddressBarFocused {
                    submitFromAddressBar()
                    return .handled
                }
                return .ignored
            }
            .overlay { WalletWindowHost(browserState: browserState) }
            .overlay { onboardingOverlay }
            .overlay { appLockOverlay }
            .overlay { encryptionRecoveryOverlay }
            .overlay(alignment: .topTrailing) {
                if !NotificationManager.shared.inAppNotifications.isEmpty {
                    InAppNotificationHost(
                        notifications: NotificationManager.shared.inAppNotifications,
                        glassEnabled: glassEnabled,
                        toolbarMaterial: toolbarMaterial,
                        onDismiss: { id in
                            NotificationManager.shared.dismiss(id)
                        },
                        onInteract: { notification in
                            NotificationManager.shared.dismiss(notification.id)
                        }
                    )
                    .padding(.top, 90)
                    .padding(.trailing, 16)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
            }
            // Fluid centered floating panel for Local AI Chat (extracted).
            .overlay {
                LocalAIChatFloatingPanel(
                    isPresented: $browserState.showingLocalAIChat,
                    glassEnabled: glassEnabled,
                    content: localAIChatView
                )
            }
            // Lightweight Siri-style quick answer (Explain / Summarize from page selection).
            .overlay(alignment: .bottom) {
                QuickAnswerPopup(browserState: browserState, glassEnabled: glassEnabled)
            }
    }
}

#Preview {
    ContentView()
}

// NOTE: Data models (BrowserTab, SearXNGInstance, DownloadItem, etc.),
// SearXNGService, and WebViewRepresentable have been extracted to separate files
// for maintainability starting with Phases 8-11.
// New .swift files in this folder are auto-included thanks to FileSystemSynchronizedRootGroup.

// HomeStarfield has been moved to Views/Components/HomeStarfield.swift.
// The private inlined version was removed during ContentView extraction.

// PasswordVaultTabView has been extracted to Views/Features/PasswordVaultTabView.swift
// during the ContentView modularization effort. The call site in mainContentArea remains unchanged.
