//
//  BrowserView.swift
//  SearxlyiOS
//
//  Touch-first browser shell, Safari-style: content fills the screen (dark Searxly start page,
//  native SERP, or the WKWebView), and all chrome lives in a bottom bar — a Liquid Glass address/search
//  pill plus a toolbar (back/forward/reload/tabs/settings). Tapping the pill raises it with the keyboard.
//

import SwiftUI
import UIKit
import WebKit
import CoreSpotlight
import Translation

struct BrowserView: View {
    @State private var tabs = TabsModel()
    @State private var editingText: String = ""
    @FocusState private var addressFocused: Bool
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var showSyncReceive = false
    @State private var showLibrary = false
    @State private var libraryTab: LibraryView.Tab = .bookmarks
    @State private var showBurnConfirm = false
    @State private var showPageInfo = false
    @State private var showSummary = false
    @State private var showPageChat = false
    @State private var showReaderUnavailable = false
    @State private var showNoVideoForPiP = false
    @State private var showDownloads = false
    @State private var downloads = DownloadManager.shared
    @State private var intentRouter = IntentRouter.shared
    @State private var translator = PageTranslator.shared
    @State private var showVoiceSearch = false
    @State private var showQRScanner = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var debugForceFocused = false
    /// Live horizontal offset while swiping the bottom bar to switch tabs — interactive (tracks the
    /// finger frame-by-frame), so it feels like Safari instead of a lurch on release.
    @State private var dragX: CGFloat = 0
    /// Screen width, captured continuously so the swipe thresholds and previews are exact. Seeded with
    /// the current screen bounds so the gesture is correct even before the first layout pass.
    @State private var contentWidth: CGFloat = BrowserView.initialScreenWidth
    @Environment(\.colorScheme) private var colorScheme

    /// The active window scene's screen width (`UIScreen.main` is deprecated in iOS 26). This is only a
    /// seed — `widthReader` overwrites it on the first layout pass — so a missing scene falls back to a
    /// typical iPhone width rather than failing.
    private static var initialScreenWidth: CGFloat {
        let width = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen.bounds.width
        return width ?? 393
    }

    private var active: BrowserModel { tabs.active }

    /// Drives the bar's focused *appearance* (flush bar, Cancel, hidden toolbar). Normally just the real
    /// focus state; a DEBUG launch hook can force it on so the focused look is screenshottable headless.
    private var barFocused: Bool { addressFocused || debugForceFocused }

    /// Safari-style minimized chrome while scrolling a web page. Focus always wins (expanded).
    private var barCollapsed: Bool {
        active.chromeCollapsed && !barFocused && active.content == .web
    }

    private var trimmedQuery: String { editingText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The empty-field quick-access panel is worth showing if there's anything for it — Top Sites
    /// (history) or bookmarks to fall back on, recent searches, or a Paste-and-Go clipboard string.
    /// `hasStrings` is banner-free (it doesn't read the clipboard), so this stays privacy-clean.
    private var hasQuickPanelContent: Bool {
        // Private tabs hide the personal sections, so their panel has content only when the
        // clipboard offers Paste and Go.
        if active.isPrivate { return UIPasteboard.general.hasStrings }
        let lib = LibraryStore.shared
        return !lib.recentSearches.isEmpty || !lib.history.isEmpty || !lib.bookmarks.isEmpty
            || UIPasteboard.general.hasStrings
    }

    var body: some View {
        browserShell
            .background { keyboardShortcuts }
            .overlay { privacySnapshotCover }
            .overlay { readerLoadingOverlay }
            .animation(.easeOut(duration: 0.18), value: active.readerLoading)
            .onAppear {
                syncEditing()
                consumePendingIntents()
                #if DEBUG
                runDebugLaunchHooks()
                #endif
            }
            .onChange(of: intentRouter.pendingSearch) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingPrivateTab) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingNewSearch) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingReopenLast) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingURL) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingDownloads) { consumePendingIntents() }
            .onChange(of: intentRouter.pendingSummarize) { consumePendingIntents() }
            .onChange(of: active.id) { syncEditing() }
            .onChange(of: active.displayText) { if !addressFocused { syncEditing() } }
            .onChange(of: downloads.startedGeneration) { showDownloads = true }
            .onChange(of: addressFocused) { _, focused in
                editingText = focused ? active.editText : active.displayText
                if focused { active.expandChrome() }
            }
            // Owns the on-device translation session + selection actions (extracted to a modifier —
            // the inline chain pushed body past the type-checker's budget).
            .modifier(TranslationHost(translator: translator, model: active))
            .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoffURL != nil) { activity in
                configureHandoff(activity)
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let url = URL(string: id) {
                    intentRouter.pendingURL = url
                }
            }
            .onOpenURL { handleDeepLink($0) }
    }

    /// Core shell + sheets/alerts — split out of `body` so the type-checker stays happy.
    private var browserShell: some View {
        browserStage
            .animation(.easeOut(duration: 0.16), value: addressFocused)
            .background(widthReader)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $showTabs) { TabSwitcherView(tabs: tabs) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showSyncReceive) {
                NavigationStack { ReceiveSyncView() }
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showLibrary) {
                LibraryView(
                    initialTab: libraryTab,
                    onOpen: { url in tabs.active.load(url) },
                    onOpenInNewTab: { url in tabs.newTab(url: url); syncEditing() }
                )
            }
            .sheet(isPresented: $showPageInfo) { PageInfoView(model: active) }
            .sheet(isPresented: $showDownloads) { DownloadsView() }
            .sheet(isPresented: $showSummary) { SummarySheet(model: active) }
            .sheet(isPresented: $showPageChat) { PageChatSheet(model: active) }
            .sheet(item: readerBinding) { article in ReaderView(article: article) }
            .alert(L("No video on this page."), isPresented: $showNoVideoForPiP) {
                Button(L("Done"), role: .cancel) {}
            }
            .alert(L("No readable article on this page."), isPresented: $showReaderUnavailable) {
                Button(L("Done"), role: .cancel) {}
            }
            .confirmationDialog(L("Close all tabs and clear website data?"),
                                isPresented: $showBurnConfirm, titleVisibility: .visible) {
                Button(L("Close Tabs & Clear Data"), role: .destructive) {
                    withAnimation(.smooth) { tabs.burn() }
                    syncEditing()
                }
            } message: {
                Text(L("Closes every tab (including private) and erases cookies, caches, and site data. Bookmarks and history are kept."))
            }
            .alert(L("Open in another app?"), isPresented: externalOpenPresented) {
                Button(L("Cancel"), role: .cancel) { active.pendingExternalURL = nil }
                Button(L("Open")) { active.confirmExternalOpen() }
            } message: {
                Text(active.pendingExternalURL?.absoluteString ?? "")
            }
            .alert(L("Site doesn't support HTTPS"), isPresented: httpFallbackPresented) {
                Button(L("Go Back"), role: .cancel) { active.httpFallbackURL = nil }
                Button(L("Use HTTP")) { active.continueWithHTTP() }
            } message: {
                Text(httpsFallbackMessage)
            }
    }

    private var browserStage: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            if dragX != 0 { swipePreviews }
            content.offset(x: dragX)
            if addressFocused {
                Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { addressFocused = false }
                    .transition(.opacity)
            }
            if addressFocused && (!trimmedQuery.isEmpty || hasQuickPanelContent) {
                if trimmedQuery.isEmpty && active.content == .home && !active.isPrivate {
                    // Home, empty field: the bar "expands" into a full browse panel — top-sites
                    // grid + recent searches filling the space above the keyboard (Safari's
                    // focused start page). Typing switches to the compact card below; private
                    // tabs keep the compact card (their panel is Paste and Go at most).
                    SuggestionsView(
                        query: editingText,
                        allowRemote: !active.isPrivate,
                        style: .expanded,
                        onSearch: { q in active.submit(q); addressFocused = false },
                        onOpen: { url in active.load(url); addressFocused = false }
                    )
                    .padding(.horizontal, 9)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        SuggestionsView(
                            query: editingText,
                            allowRemote: !active.isPrivate,
                            isPrivate: active.isPrivate,
                            onSearch: { q in active.submit(q); addressFocused = false },
                            onOpen: { url in active.load(url); addressFocused = false }
                        )
                        .padding(.horizontal, 9)
                        .padding(.bottom, 6)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func configureHandoff(_ activity: NSUserActivity) {
        guard let url = handoffURL else { return }
        activity.webpageURL = url
        activity.title = active.pageTitle.isEmpty ? url.absoluteString : active.pageTitle
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
    }

    #if DEBUG
    private func runDebugLaunchHooks() {
        let env = ProcessInfo.processInfo.environment
        if let q = env["SEARXLY_DEMO_QUERY"], !q.isEmpty {
            let scope = SearchScope(rawValue: env["SEARXLY_DEMO_SCOPE"] ?? "") ?? .web
            active.runSearch(q, scope: scope)
            syncEditing()
        }
        if let raw = env["SEARXLY_DEMO_URL"], let url = URL(string: raw) {
            active.load(url)
            syncEditing()
        }
        if env["SEARXLY_DEMO_FOCUS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addressFocused = true }
            if let text = env["SEARXLY_DEMO_TEXT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { editingText = text }
            }
        }
        if env["SEARXLY_DEMO_APPEARANCE"] == "focused" { debugForceFocused = true }
        if env["SEARXLY_DEMO_PRIVATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tabs.enterPrivateMode(); syncEditing() }
        }
        if env["SEARXLY_DEMO_SEED"] == "1" { seedDemoLibrary() }
        if let raw = env["SEARXLY_DEMO_SECOND_URL"], let url = URL(string: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { tabs.newTab(url: url) }
        }
        if env["SEARXLY_DEMO_COLLAPSE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { active.debugForceCollapsed() }
        }
        if env["SEARXLY_DEMO_SWIPE"] == "1" {
            active.load(URL(string: "https://en.wikipedia.org/wiki/Tiger")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                _ = tabs.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Lion")!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { tabs.switchToPrevious() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { dragX = -175 }
        }
        switch env["SEARXLY_DEMO_PANEL"] {
        case "settings": showSettings = true
        case "library": seedDemoLibrary(); showLibrary = true
        case "tabs": DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { openTabs() }
        case "pageinfo": DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { showPageInfo = true }
        case "summary": DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { showSummary = true }
        case "reader": DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { openReader() }
        case "downloads": DownloadManager.shared.seedDemo(); showDownloads = true
        case "reading":
            ReadingListStore.shared.seedDemo()
            libraryTab = .reading
            showLibrary = true
        default: break
        }
    }
    #endif

    /// Routes a `searxly://` deep link into the browser via IntentRouter. Hosts:
    /// `search` (focus a new search), `private` (new private tab), `reopen` (reopen last tab),
    /// `open?url=…` (open a specific page).
    private func handleDeepLink(_ url: URL) {
        // Plain web links handed to us (Share extension, another app, or as the default browser)
        // open in a new tab.
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            intentRouter.pendingURL = url
            return
        }
        // An AirDropped / Files-opened sync bundle goes straight to the Receive screen. The file
        // is read here while the security scope is valid; the sheet then only needs the bytes.
        if url.isFileURL, url.pathExtension.lowercased() == SyncFile.fileExtension {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                SyncInbox.shared.pending = (data, url.lastPathComponent)
                showSyncReceive = true
            }
            return
        }
        guard url.scheme == "searxly" else { return }
        switch url.host {
        case "search":  intentRouter.pendingNewSearch = true
        case "private": intentRouter.pendingPrivateTab = true
        case "reopen":  intentRouter.pendingReopenLast = true
        case "open":
            if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "url" })?.value,
               let target = URL(string: value), (target.scheme?.hasPrefix("http") ?? false) {
                intentRouter.pendingURL = target
            }
        default: break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch active.content {
        case .home:
            HomeView(
                onOpenFavorite: { url in active.load(url) },
                onOpenFavoriteNewTab: { url in tabs.newTab(url: url); syncEditing() },
                onOpenStory: { result in active.open(result) },
                onSeeAllNews: { query in active.runSearch(query, scope: .news) },
                onPullToSearch: { addressFocused = true },
                onRecentSearch: { query in active.runSearch(query) },
                onOpenHistory: { libraryTab = .history; showLibrary = true },
                onOpenSettings: { showSettings = true },
                isPrivate: active.isPrivate
            )
        case .results:
            SearchResultsView(model: active)
        case .web:
            // The page ends ABOVE the floating glass bar — see the note on `webContent` for why it
            // does not draw underneath it. (This branch used to do the opposite; the comment that
            // described the old model outlived it.)
            webContent
        }
    }

    private var webContent: some View {
        ZStack(alignment: .top) {
            WKWebViewRepresentable(webView: active.webView, model: active)
                .id(active.id)
                // Full-bleed under the floating glass bar (Safari's look): the page scrolls
                // beneath the translucent chrome. Clearance comes from the scroll inset
                // (BrowserModel.barInset covers the bar) and the chrome-lift stylesheet, which
                // raises fixed cookie/consent banners above the bar so they stay tappable.
                .ignoresSafeArea(.container, edges: .bottom)
            if let message = active.loadError {
                ErrorPageView(
                    host: active.webView.url?.host ?? "",
                    message: message,
                    onRetry: { active.loadError = nil; active.webView.reload() },
                    onBack: { active.loadError = nil; active.goBack() }
                )
            }
            // A child view so per-frame progress updates re-render ONLY this bar,
            // not the whole browser shell.
            WebProgressBar(model: active)
        }
    }

    private func syncEditing() {
        if !addressFocused { editingText = active.displayText }
    }

    private var readerBinding: Binding<ReaderArticle?> {
        Binding(get: { active.readerArticle }, set: { active.readerArticle = $0 })
    }

    private func openReader() {
        Task {
            if await active.prepareReader() == false { showReaderUnavailable = true }
        }
    }

    /// The page to advertise for Handoff: the active tab's web URL, and only for normal (non-private)
    /// tabs. Nil disables the activity entirely (home, native SERP, or any private tab).
    private var handoffURL: URL? {
        guard !active.isPrivate, let s = active.currentURLString else { return nil }
        return URL(string: s)
    }

    /// Consumes any action handed over by an App Intent, home-screen Quick Action, or a tapped
    /// Spotlight result — all delivered through IntentRouter on the main actor.
    private func consumePendingIntents() {
        if let q = intentRouter.pendingSearch {
            intentRouter.pendingSearch = nil
            let tab = tabs.newTab()
            tab.runSearch(q)
            syncEditing()
        }
        if intentRouter.pendingPrivateTab {
            intentRouter.pendingPrivateTab = false
            tabs.enterPrivateMode()
            syncEditing()
        }
        if intentRouter.pendingNewSearch {
            intentRouter.pendingNewSearch = false
            tabs.newTab()
            syncEditing()
            addressFocused = true
        }
        if intentRouter.pendingReopenLast {
            intentRouter.pendingReopenLast = false
            tabs.reopenMostRecent()
            syncEditing()
        }
        if let url = intentRouter.pendingURL {
            intentRouter.pendingURL = nil
            tabs.newTab(url: url)
            syncEditing()
        }
        if intentRouter.pendingDownloads {
            intentRouter.pendingDownloads = false
            showDownloads = true
        }
        if intentRouter.pendingSummarize {
            intentRouter.pendingSummarize = false
            // Only meaningful with a page open and the model available; otherwise the intent
            // just opens the app (no dead sheet).
            if active.content == .web, PageIntelligence.isAvailable {
                showSummary = true
            }
        }
    }

    /// Hardware-keyboard shortcuts (iPad / Magic Keyboard), Safari-style. Hidden zero-size
    /// buttons register their key equivalents without appearing in the UI.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { tabs.newTab(); syncEditing() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") {
                if tabs.privateMode { tabs.newTab() } else { tabs.enterPrivateMode() }
                syncEditing()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { addressFocused = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("") { withAnimation(.smooth) { tabs.close(active) }; syncEditing() }
                .keyboardShortcut("w", modifiers: .command)
            Button("") { active.reloadOrStop() }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { if active.content == .web { active.findOnPage() } }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { tabs.reopenMostRecent(); syncEditing() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { openTabs() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("") { if active.content == .web { active.toggleBookmarkCurrent() } }
                .keyboardShortcut("d", modifiers: .command)
            Button("") { libraryTab = .history; showLibrary = true }
                .keyboardShortcut("y", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var externalOpenPresented: Binding<Bool> {
        Binding(
            get: { active.pendingExternalURL != nil },
            set: { if !$0 { active.pendingExternalURL = nil } }
        )
    }


    private var httpFallbackPresented: Binding<Bool> {
        Binding(
            get: { active.httpFallbackURL != nil },
            set: { if !$0 { active.httpFallbackURL = nil } }
        )
    }

    private var httpsFallbackMessage: String {
        let host = active.httpFallbackURL?.host ?? L("This site")
        return String(format: L("“%@” couldn't be loaded securely. Load it over an unencrypted connection just for this session?"), host)
    }

    @ViewBuilder
    private var readerLoadingOverlay: some View {
        if active.readerLoading {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(Brand.text)
                    Text(L("Opening Reader…"))
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(22)
                .searxlyGlassCard(cornerRadius: 18)
            }
            .transition(.opacity)
            .allowsHitTesting(true)
        }
    }

    #if DEBUG
    private func seedDemoLibrary() {
        let lib = LibraryStore.shared
        if lib.bookmarks.isEmpty {
            lib.toggleBookmark(url: "https://www.swift.org", title: "Swift.org — Welcome to Swift.org")
            lib.toggleBookmark(url: "https://news.ycombinator.com", title: "Hacker News")
        }
        lib.seedDemoHistory()
    }
    #endif

    /// Opaque cover drawn in the app-switcher snapshot (and any inactive / interrupted state) whenever
    /// a private tab is open — so a private page never leaks into the multitasking preview, even when
    /// App Lock is off. Renders nothing while the scene is active or when no private tabs exist.
    @ViewBuilder private var privacySnapshotCover: some View {
        if scenePhase != .active && (tabs.privateMode || tabs.hasPrivateTabs) {
            ZStack {
                Brand.bg.ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .scaledFont(size: 26, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                    Text(L("Private Mode"))
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Bottom bar (Safari-style floating Liquid Glass card)

    private var bottomBar: some View {
        VStack(spacing: barCollapsed ? 0 : 8) {
            HStack(spacing: 10) {
                addressPill
                if barFocused {
                    Button(L("Cancel")) { addressFocused = false; debugForceFocused = false }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Brand.text)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            // Hairline divider between the address field and the toolbar — only when both show.
            if !barFocused && !barCollapsed {
                Rectangle()
                    .fill(Brand.hairline.opacity(0.85))
                    .frame(height: 0.5)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }

            // Hidden while focused (keyboard up) and while minimized by scrolling. Structural branches
            // around the TOOLBAR are fine — never around the address TextField.
            if !barFocused && !barCollapsed {
                toolbarRow
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, barCollapsed ? 8 : 12)
        .padding(.top, barCollapsed ? 5 : 10)
        .padding(.bottom, barCollapsed ? 5 : 9)
        // ONE stable surface in both states — a tinted, rounded Liquid Glass card. It must never switch
        // background *type* by focus: doing so rebuilds the TextField inside and drops the keyboard.
        // Rounded (never flush) means no hard rim lines either.
        .glassEffect(.regular.tint(barGlassTint), in: .rect(cornerRadius: barCollapsed ? 22 : 28))
        .overlay {
            RoundedRectangle(cornerRadius: barCollapsed ? 22 : 28, style: .continuous)
                .strokeBorder(barRimStroke, lineWidth: 0.6)
        }
        // Soft lift so the dock reads as floating chrome, not a stuck slab.
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.38 : 0.10),
                radius: barCollapsed ? 10 : 18, y: barCollapsed ? 2 : 6)
        .padding(.horizontal, barCollapsed ? 68 : 10)
        .padding(.bottom, 4)
        .animation(.smooth(duration: 0.28), value: barFocused)
        .animation(.smooth(duration: 0.24), value: barCollapsed)
    }

    /// Slight darkening of the Liquid Glass dock — eased back from the previous (too-dark) value.
    /// Private tabs get a noticeably deeper tint so the mode is always visible at a glance.
    private var barGlassTint: Color {
        if active.isPrivate {
            return colorScheme == .dark
                ? Color(red: 0.08, green: 0.06, blue: 0.16).opacity(0.72)
                : Color(red: 0.28, green: 0.22, blue: 0.48).opacity(0.14)
        }
        return colorScheme == .dark ? Color.black.opacity(0.36) : Color.black.opacity(0.045)
    }

    /// Rim light on the dock: brighter when focused (keyboard up), muted when collapsed.
    private var barRimStroke: Color {
        if active.isPrivate {
            return colorScheme == .dark
                ? Color(red: 0.55, green: 0.48, blue: 0.95).opacity(barFocused ? 0.28 : 0.14)
                : Color(red: 0.35, green: 0.28, blue: 0.70).opacity(barFocused ? 0.22 : 0.12)
        }
        return Brand.text.opacity(barFocused ? 0.14 : (barCollapsed ? 0.05 : 0.08))
    }

    // MARK: - Interactive tab swipe (Safari-style)

    /// The tab to the left / right of the active one within the current space (nil at the ends).
    private var prevTab: BrowserModel? {
        let s = tabs.spaceTabs
        guard let i = s.firstIndex(where: { $0.id == tabs.activeID }), i > 0 else { return nil }
        return s[i - 1]
    }
    private var nextTab: BrowserModel? {
        let s = tabs.spaceTabs
        guard let i = s.firstIndex(where: { $0.id == tabs.activeID }), i < s.count - 1 else { return nil }
        return s[i + 1]
    }

    /// One interactive drag on the bottom bar. `.onChanged` moves `dragX` with the finger every frame
    /// (this is what makes it fluid — the old code only reacted on release), and `.onEnded` settles with
    /// a velocity-aware spring: horizontal → switch tabs (or a new tab past the last), up → the tab grid,
    /// down → reopen the last closed tab.
    private var barDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !barFocused else { return }
                // Track clearly-horizontal drags only; vertical intents resolve on release.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = rubberBanded(value.translation.width)
            }
            .onEnded { value in
                guard !barFocused else { dragX = 0; return }
                endBarDrag(value)
            }
    }

    /// Resistance past the ends: you can page LEFT past the last tab (that reveals a new tab), but not
    /// RIGHT past the first; and a one-screen clamp so a page never over-travels.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let w = contentWidth
        if x > 0, prevTab == nil { return rubber(x, w) }
        return max(-w, min(w, x))
    }

    private func rubber(_ x: CGFloat, _ w: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        return (1 - 1 / (x * c / w + 1)) * w
    }

    private func endBarDrag(_ value: DragGesture.Value) {
        let t = value.translation
        let v = value.velocity
        let w = contentWidth

        // Mostly-vertical flick → grid (up) / reopen last closed (down).
        if abs(t.height) > abs(t.width), abs(t.height) > 40 {
            dragX = 0
            if t.height < 0 {
                openTabs()
            } else if !tabs.recentlyClosed.isEmpty {
                Haptics.tick(); tabs.reopenMostRecent(); syncEditing()
            }
            return
        }

        // Horizontal: commit if dragged far enough OR flicked hard enough (velocity), else snap back.
        let goLeft  = dragX < -w * 0.30 || (v.width < -500 && dragX < -8)
        let goRight = dragX >  w * 0.30 || (v.width >  500 && dragX >  8)

        if goLeft {
            if nextTab != nil { commitSwitch(toNext: true) } else { commitNewTab() }
        } else if goRight, prevTab != nil {
            commitSwitch(toNext: false)
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { dragX = 0 }
        }
    }

    /// Slide the current page fully out, then swap to the neighbour and reset the offset — the incoming
    /// snapshot was already at x=0, so the live view replaces it with no visible jump.
    private func commitSwitch(toNext: Bool) {
        Haptics.tick()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragX = toNext ? -contentWidth : contentWidth
        } completion: {
            if toNext { tabs.switchToNext() } else { tabs.switchToPrevious() }
            dragX = 0
            syncEditing()
        }
    }

    private func commitNewTab() {
        Haptics.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragX = -contentWidth
        } completion: {
            _ = tabs.newTab()
            dragX = 0
            syncEditing()
        }
    }

    // MARK: - Swipe previews

    /// Captures the live screen width so the swipe math is exact (and updates on rotation).
    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, w in contentWidth = max(w, 1) }
        }
    }

    /// The adjacent tab(s), rendered behind `content` only while swiping: a live snapshot when we have
    /// one, else a light identity placeholder; a "+" page when paging past the last tab toward a new one.
    private var swipePreviews: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack {
                if dragX > 0, let prev = prevTab {
                    tabPreview(prev).offset(x: dragX - w)
                } else if dragX < 0 {
                    Group {
                        if let next = nextTab { tabPreview(next) } else { newTabPreview }
                    }
                    .offset(x: dragX + w)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func tabPreview(_ tab: BrowserModel) -> some View {
        ZStack {
            Brand.bg
            if let snapshot = tab.snapshot {
                Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: tab.isPrivate ? "hand.raised.fill" : "magnifyingglass")
                        .scaledFont(size: 24, weight: .light)
                        .foregroundStyle(Brand.textTertiary)
                    Text(previewLabel(tab))
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 40)
                }
            }
        }
        .clipped()
    }

    private var newTabPreview: some View {
        ZStack {
            Brand.bg
            Image(systemName: "plus")
                .scaledFont(size: 30, weight: .light)
                .foregroundStyle(Brand.textTertiary)
        }
    }

    private func previewLabel(_ tab: BrowserModel) -> String {
        switch tab.content {
        case .home:    return L("New Tab")
        case .results: return tab.searchQuery
        case .web:     return tab.webView.url?.host ?? tab.sessionURL?.host ?? (tab.pageTitle.isEmpty ? L("Tab") : tab.pageTitle)
        }
    }

    private func openTabs() {
        Haptics.tick()
        active.captureSnapshot() // fresh card for the active tab
        showTabs = true
    }

    private var addressPill: some View {
        HStack(spacing: barCollapsed ? 6 : 9) {
            // Leading status: site lock / private / search. On web pages the lock is tappable → Page Info.
            // Always present (opacity-gated when focused) so the TextField never jumps position on focus.
            Button {
                if !barFocused, active.content == .web { showPageInfo = true }
            } label: {
                ZStack {
                    if !barFocused, active.content == .web, let host = addressHost {
                        // Live favicon chip when we know the host — Safari-grade wayfinding.
                        FaviconView(host: host, size: barCollapsed ? 16 : 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Image(systemName: pillIcon)
                            .scaledFont(size: barCollapsed ? 12 : 14, weight: .semibold)
                            .foregroundStyle(pillIconColor)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: barCollapsed ? 18 : 22, height: barCollapsed ? 18 : 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(barFocused || active.content != .web)
            .opacity(barFocused ? 0 : 1)
            .frame(width: barFocused ? 0 : (barCollapsed ? 18 : 22))
            .accessibilityLabel(active.content == .web ? "Page info" : (active.isPrivate ? "Private search" : "Search"))

            TextField(L("Search or enter address"), text: $editingText)
                .textFieldStyle(.plain)
                .scaledFont(size: barCollapsed ? 13.5 : 16.5, weight: barFocused ? .regular : .medium)
                .foregroundStyle(Brand.text)
                .tint(Brand.text)
                .focused($addressFocused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                .multilineTextAlignment(barFocused ? .leading : .center)
                .lineLimit(1)
                .onSubmit {
                    active.submit(editingText)
                    addressFocused = false
                }

            // Trailing cluster — always laid out so the field width stays stable.
            HStack(spacing: 4) {
                if !barFocused && active.content == .web && !barCollapsed {
                    if active.pageBlockedCount > 0 {
                        Button { showPageInfo = true } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "shield.fill")
                                    .scaledFont(size: 10, weight: .semibold)
                                Text("\(active.pageBlockedCount)")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Brand.text.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(active.pageBlockedCount) " + L("trackers blocked on this page"))
                    }
                    // Tap = reload/stop; long-press = Safari's reload extras (desktop site).
                    Menu {
                        Button { active.toggleDesktopSite() } label: {
                            Label(active.isDesktopSite ? L("Request Mobile Website") : L("Request Desktop Website"),
                                  systemImage: active.isDesktopSite ? "iphone" : "desktopcomputer")
                        }
                    } label: {
                        Image(systemName: active.isLoading ? "xmark" : "arrow.clockwise")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Brand.text.opacity(0.06)))
                            .contentShape(Circle())
                    } primaryAction: {
                        active.reloadOrStop()
                    }
                    .accessibilityLabel(active.isLoading ? "Stop" : "Reload")
                }

                if barFocused && !editingText.isEmpty {
                    Button { editingText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundStyle(Brand.textTertiary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear"))
                }

                // Empty focused field: voice search + code scanner (the clear button's slot).
                if barFocused && editingText.isEmpty {
                    Button { showVoiceSearch = true } label: {
                        Image(systemName: "mic")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Voice search"))
                    .sheet(isPresented: $showVoiceSearch) {
                        VoiceSearchSheet { text in
                            addressFocused = false
                            active.submit(text)
                        }
                        .preferredColorScheme(.dark)
                    }

                    Button { showQRScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(Brand.textSecondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Scan Code"))
                    .sheet(isPresented: $showQRScanner) {
                        QRScannerSheet { payload in
                            addressFocused = false
                            active.submit(payload)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, barCollapsed ? 12 : 14)
        .padding(.vertical, barCollapsed ? 7 : 11)
        // Recessed field inside the glass card (Safari look) — not a second glass layer.
        .background(
            Capsule()
                .fill(Brand.text.opacity(barFocused ? 0.12 : (barCollapsed ? 0.05 : 0.075)))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    Brand.text.opacity(barFocused ? 0.16 : 0.06),
                    lineWidth: barFocused ? 1.0 : 0.5
                )
        )
        // Focus ring glow — calm, not neon.
        .shadow(color: Brand.text.opacity(barFocused ? (colorScheme == .dark ? 0.18 : 0.08) : 0),
                radius: barFocused ? 10 : 0, y: 0)
        // Safari's signature: swipe the address pill sideways to switch tabs (interactive — the page
        // tracks your finger), up for the grid. The mask (not a structural branch — see the typing-bug
        // rule) disables it entirely while editing, so a drag can never fight the TextField.
        .simultaneousGesture(barDrag, including: barFocused ? .none : .all)
    }

    private var pillIcon: String {
        if active.isPrivate { return "hand.raised.fill" }
        switch active.content {
        case .web:     return "lock.fill"
        case .results: return "magnifyingglass"
        case .home:    return "magnifyingglass"
        }
    }

    private var pillIconColor: Color {
        if active.isPrivate {
            return colorScheme == .dark
                ? Color(red: 0.72, green: 0.66, blue: 1.0).opacity(0.9)
                : Color(red: 0.38, green: 0.30, blue: 0.72)
        }
        return Brand.textTertiary
    }

    /// Host for the address-bar favicon (web only).
    private var addressHost: String? {
        guard active.content == .web else { return nil }
        let host = active.webView.url?.host ?? active.sessionURL?.host
        return host?.replacingOccurrences(of: "www.", with: "")
    }

    private var toolbarRow: some View {
        HStack(spacing: 0) {
            historyNavButton("chevron.backward", enabled: active.canGoBack,
                             items: active.backHistory) { active.goBack() }
                .accessibilityLabel(L("Back"))
            Spacer()
            historyNavButton("chevron.forward", enabled: active.canGoForward,
                             items: active.forwardHistory) { active.goForward() }
                .accessibilityLabel(L("Forward"))
            Spacer()
            pageMenu
                .accessibilityLabel(L("Page options"))
            Spacer()
            privateModeButton
            Spacer()
            libraryButton
                .accessibilityLabel(L("Bookmarks and history"))
            Spacer()
            tabsButton
                .accessibilityLabel(L("Tabs") + ", \(tabs.spaceTabs.count)")
        }
        .padding(.horizontal, 4)
        .padding(.top, 1)
        .contentShape(Rectangle())
        .simultaneousGesture(barDrag)
    }

    /// Back/forward with Safari's long-press history menu (tap = step once).
    @ViewBuilder
    private func historyNavButton(
        _ systemName: String,
        enabled: Bool,
        items: [WKBackForwardListItem],
        primary: @escaping () -> Void
    ) -> some View {
        if items.isEmpty {
            navButton(systemName, enabled: enabled, action: primary)
        } else {
            Menu {
                ForEach(items.prefix(12), id: \.self) { item in
                    Button { active.go(to: item) } label: {
                        Text(BrowserModel.historyItemLabel(item))
                    }
                }
            } label: {
                Image(systemName: systemName)
                    .scaledFont(size: 20, weight: .regular)
                    .foregroundStyle(enabled ? Brand.text : Brand.text.opacity(0.22))
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
            } primaryAction: {
                primary()
            }
            .disabled(!enabled)
        }
    }

    /// Tap = Library (bookmarks); long-press = jump straight to a shelf, or bookmark this page.
    private var libraryButton: some View {
        Menu {
            if active.content == .web, active.currentURLString != nil {
                Button { active.toggleBookmarkCurrent() } label: {
                    Label(active.isCurrentBookmarked ? L("Remove Bookmark") : L("Add Bookmark"),
                          systemImage: active.isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                }
                Divider()
            }
            Button { libraryTab = .bookmarks; showLibrary = true } label: {
                Label(L("Bookmarks"), systemImage: "book")
            }
            Button { libraryTab = .reading; showLibrary = true } label: {
                Label(L("Reading List"), systemImage: "eyeglasses")
            }
            Button { libraryTab = .history; showLibrary = true } label: {
                Label(L("History"), systemImage: "clock.arrow.circlepath")
            }
            Button { showDownloads = true } label: {
                Label(L("Downloads"), systemImage: "arrow.down.circle")
            }
        } label: {
            Image(systemName: "book")
                .scaledFont(size: 20, weight: .regular)
                .foregroundStyle(Brand.text)
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        } primaryAction: {
            libraryTab = .bookmarks
            showLibrary = true
        }
    }

    /// Tap = tab overview; long-press = quick tab actions (Safari behavior).
    private var tabsButton: some View {
        Menu {
            Button { tabs.newTab(); syncEditing() } label: {
                Label(L("New Tab"), systemImage: "plus.square")
            }
            Button {
                withAnimation(.smooth) { tabs.togglePrivateMode() }
                syncEditing()
            } label: {
                Label(tabs.privateMode ? L("Leave Private Mode") : L("Private Mode"),
                      systemImage: tabs.privateMode ? "hand.raised.slash" : "hand.raised.fill")
            }
            if !tabs.recentlyClosed.isEmpty {
                Menu {
                    ForEach(tabs.recentlyClosed) { closed in
                        Button { tabs.reopen(closed); syncEditing() } label: {
                            Text(closed.title)
                        }
                    }
                } label: {
                    Label(L("Recently Closed"), systemImage: "arrow.uturn.left.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(.smooth) { tabs.close(active) }
                syncEditing()
            } label: {
                Label(L("Close Tab"), systemImage: "xmark")
            }
            if tabs.spaceTabs.count > 1 {
                Button(role: .destructive) {
                    withAnimation(.smooth) { tabs.closeAll() }
                    syncEditing()
                } label: {
                    Label(L("Close All Tabs"), systemImage: "xmark.square")
                }
            }
        } label: {
            tabCountIcon.frame(width: 44, height: 34).contentShape(Rectangle())
        } primaryAction: {
            openTabs()
        }
    }

    /// The ⋯ menu, organized in fixed groups (top = act on this page, bottom = app-level):
    ///   share & save · Intelligence · View · Tabs · app. Shields intentionally live behind
    ///   the LOCK icon (Page Info), not here.
    private var pageMenu: some View {
        Menu {
            if active.content == .web,
               let urlStr = active.currentURLString,
               let url = URL(string: urlStr) {
                // ── Act on this page ──
                Section {
                    Button { active.toggleBookmarkCurrent() } label: {
                        Label(active.isCurrentBookmarked ? L("Remove Bookmark") : L("Add Bookmark"),
                              systemImage: active.isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    Button {
                        ReadingListStore.shared.toggle(url: urlStr, title: active.pageTitle)
                    } label: {
                        Label(ReadingListStore.shared.contains(urlStr) ? L("Remove from Reading List") : L("Add to Reading List"),
                              systemImage: "eyeglasses")
                    }
                    ShareLink(item: url) { Label(L("Share…"), systemImage: "square.and.arrow.up") }
                    if let clean = active.cleanLinkString, clean != urlStr {
                        Menu {
                            Button { UIPasteboard.general.string = urlStr } label: {
                                Label(L("Copy Link"), systemImage: "doc.on.doc")
                            }
                            Button { UIPasteboard.general.string = clean } label: {
                                Label(L("Copy Clean Link"), systemImage: "link.badge.plus")
                            }
                        } label: {
                            Label(L("Copy Link"), systemImage: "doc.on.doc")
                        }
                    } else {
                        Button { UIPasteboard.general.string = urlStr } label: {
                            Label(L("Copy Link"), systemImage: "doc.on.doc")
                        }
                    }
                    Button { UIApplication.shared.open(url) } label: {
                        Label(L("Open in Safari"), systemImage: "safari")
                    }
                }

                if PageIntelligence.isAvailable {
                    Section(L("Intelligence")) {
                        Button { showSummary = true } label: {
                            Label(L("Summarize Page"), systemImage: "apple.intelligence")
                        }
                        Button { showPageChat = true } label: {
                            Label(L("Ask About This Page"), systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                }

                Section(L("View")) {
                    Button { openReader() } label: {
                        Label(active.readerLoading ? L("Opening Reader…") : L("Reader"),
                              systemImage: "doc.plaintext")
                    }
                    .disabled(active.readerLoading || active.isLoading)
                    Button { translator.toggleTranslation(for: active.webView) } label: {
                        Label(translator.isTranslated(active.webView) ? L("Show Original") : L("Translate Page"),
                              systemImage: "character.bubble")
                    }
                    .disabled(translator.isTranslating || active.isLoading)
                    Button {
                        Haptics.tick()
                        active.findOnPage()
                    } label: {
                        Label(L("Find on Page…"), systemImage: "doc.text.magnifyingglass")
                    }
                    Menu {
                        Button { active.adjustTextZoom(-0.1) } label: {
                            Label(L("Smaller"), systemImage: "textformat.size.smaller")
                        }
                        Button { active.resetTextZoom() } label: {
                            Label(L("Default Size"), systemImage: "textformat.size")
                        }
                        Button { active.adjustTextZoom(0.1) } label: {
                            Label(L("Larger"), systemImage: "textformat.size.larger")
                        }
                    } label: {
                        Label(L("Text Size"), systemImage: "textformat")
                    }
                    // Offered whenever the page has media, because plenty of players (YouTube's
                    // among them) never expose a PiP control of their own — this is the only way in.
                    Button {
                        Haptics.tick()
                        Task {
                            if await active.togglePictureInPicture() == false { showNoVideoForPiP = true }
                        }
                    } label: {
                        Label(active.isInPictureInPicture ? L("Stop Picture in Picture")
                                                          : L("Picture in Picture"),
                              systemImage: "pip.enter")
                    }
                    Button { active.toggleDesktopSite() } label: {
                        Label(active.isDesktopSite ? L("Request Mobile Website") : L("Request Desktop Website"),
                              systemImage: active.isDesktopSite ? "iphone" : "desktopcomputer")
                    }
                }
            }

            Section(L("Tabs")) {
                Button { tabs.newTab(); syncEditing() } label: {
                    Label(L("New Tab"), systemImage: "plus.square")
                }
                Button {
                    withAnimation(.smooth) { tabs.togglePrivateMode() }
                    syncEditing()
                } label: {
                    Label(tabs.privateMode ? L("Leave Private Mode") : L("Private Mode"),
                          systemImage: tabs.privateMode ? "hand.raised.slash" : "hand.raised.fill")
                }
                if active.content == .web, let urlStr = active.currentURLString {
                    Button {
                        if let u = URL(string: urlStr) { tabs.newTab(url: u, isPrivate: active.isPrivate) }
                        syncEditing()
                    } label: {
                        Label(L("Duplicate Tab"), systemImage: "plus.square.on.square")
                    }
                }
            }

            Section {
                Button { showDownloads = true } label: {
                    Label(downloads.badgeCount > 0 ? "\(L("Downloads")) (\(downloads.badgeCount))" : L("Downloads"),
                          systemImage: "arrow.down.circle")
                }
                Button { showSettings = true } label: {
                    Label(L("Settings"), systemImage: "gearshape")
                }
                Button(role: .destructive) { showBurnConfirm = true } label: {
                    Label(L("Close Tabs & Clear Data"), systemImage: "flame")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 19, weight: .regular)
                .foregroundStyle(Brand.text)
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
    }

    private var tabCountIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Brand.text, lineWidth: 1.7)
                .frame(width: 22, height: 22)
            Text("\(tabs.spaceTabs.count)")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Brand.text)
        }
    }

    private func navButton(_ systemName: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 20, weight: .regular)
                .foregroundStyle(enabled ? Brand.text : Brand.text.opacity(0.22))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Bottom-bar Private Mode toggle — the always-visible entry (the tab overview holds the other).
    /// Filled indigo hand when on, outline when off. Leaving wipes the private session immediately
    /// (the user's choice); the icon flip + haptic + indigo chrome fade are the feedback.
    private var privateModeButton: some View {
        Button {
            Haptics.tap()
            withAnimation(.smooth) { tabs.togglePrivateMode() }
            syncEditing()
        } label: {
            Image(systemName: tabs.privateMode ? "hand.raised.fill" : "hand.raised")
                .scaledFont(size: 20, weight: .regular)
                .foregroundStyle(tabs.privateMode
                                 ? Color(red: 0.72, green: 0.66, blue: 1.0)
                                 : Brand.text)
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tabs.privateMode ? L("Leave Private Mode") : L("Private Mode"))
    }
}

/// Native monochrome error page for dead-end loads (offline, DNS, TLS…).
private struct ErrorPageView: View {
    let host: String
    let message: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .scaledFont(size: 36, weight: .light)
                    .foregroundStyle(Brand.textTertiary)
                if !host.isEmpty {
                    Text(host)
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(Brand.text)
                }
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.horizontal, 44)
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Text(L("Go Back"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Brand.text)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Brand.surfaceHi, in: Capsule())
                    }
                    Button(action: onRetry) {
                        Text(L("Try Again"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.bg)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Brand.text, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Isolates the per-frame `estimatedProgress` observation from the rest of the shell.
private struct WebProgressBar: View {
    let model: BrowserModel

    var body: some View {
        if model.isLoading {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(Brand.text)
        }
    }
}

#Preview {
    BrowserView()
}

// MARK: - Translation + selection-intelligence host

/// Attaches the on-device translation session + failure alert, and presents the text-selection
/// edit-menu actions (Explain This → seeded page chat; Translate This → system translation
/// popover). Lives in its own modifier so the browser shell's already-long chain doesn't grow
/// (the type-checker gave out when it did).
private struct TranslationHost: ViewModifier {
    @Bindable var translator: PageTranslator
    @Bindable var model: BrowserModel

    private struct ExplainSeed: Identifiable {
        let id = UUID()
        let question: String
    }

    @State private var explainSeed: ExplainSeed?
    @State private var selectionToTranslate = ""
    @State private var showSelectionTranslation = false

    func body(content: Content) -> some View {
        content
            .translationTask(translator.configuration) { session in
                await translator.run(session)
            }
            .alert(translator.failureMessage ?? "", isPresented: presented) {
                Button(L("Done"), role: .cancel) {}
            }
            .onChange(of: model.pendingSelectionExplain) { _, text in
                guard let text else { return }
                model.pendingSelectionExplain = nil
                explainSeed = ExplainSeed(question: text)
            }
            .onChange(of: model.pendingSelectionTranslation) { _, text in
                guard let text else { return }
                model.pendingSelectionTranslation = nil
                selectionToTranslate = text
                showSelectionTranslation = true
            }
            .sheet(item: $explainSeed) { seed in
                PageChatSheet(model: model, initialQuestion: seed.question)
            }
            .translationPresentation(isPresented: $showSelectionTranslation, text: selectionToTranslate)
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { translator.failureMessage != nil },
            set: { if !$0 { translator.failureMessage = nil } }
        )
    }
}
