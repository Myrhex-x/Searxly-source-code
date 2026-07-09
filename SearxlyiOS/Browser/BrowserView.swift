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

struct BrowserView: View {
    @State private var tabs = TabsModel()
    @State private var editingText: String = ""
    @FocusState private var addressFocused: Bool
    @State private var showTabs = false
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var libraryTab: LibraryView.Tab = .bookmarks
    @State private var showBurnConfirm = false
    @State private var showPageInfo = false
    @State private var showSummary = false
    @State private var showPageChat = false
    @State private var showReaderUnavailable = false
    @State private var showDownloads = false
    @State private var downloads = DownloadManager.shared
    @State private var intentRouter = IntentRouter.shared
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
        let lib = LibraryStore.shared
        return !lib.recentSearches.isEmpty || !lib.history.isEmpty || !lib.bookmarks.isEmpty
            || UIPasteboard.general.hasStrings
    }

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()

            // Adjacent-tab previews slide in from the side during an interactive tab swipe (rendered
            // only while a swipe is in progress, so there's zero cost at rest).
            if dragX != 0 { swipePreviews }

            // `.offset` is a render-only transform, so the web content still runs under the bar and the
            // home/SERP keep their own layout — the swipe just slides them, Safari-style.
            content
                .offset(x: dragX)

            // Focused overlay: a dim scrim (tap to dismiss) + private suggestions. Both are siblings of
            // `content` and render ABOVE the bar — they NEVER wrap the bottom bar / text field, so they
            // can't rebuild it or disturb focus (the cause of the earlier typing bug).
            if addressFocused {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { addressFocused = false }
                    .transition(.opacity)
            }
            // Non-empty query → live suggestions; empty query → the quick-access panel (Top Sites +
            // recent searches) whenever there's anything local to show.
            if addressFocused && (!trimmedQuery.isEmpty || hasQuickPanelContent) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SuggestionsView(
                        query: editingText,
                        allowRemote: !active.isPrivate,
                        onSearch: { q in active.submit(q); addressFocused = false },
                        onOpen: { url in active.load(url); addressFocused = false }
                    )
                    .padding(.horizontal, 9)
                    .padding(.bottom, 6)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: addressFocused)
        .background(widthReader)
        // safeAreaInset keeps the floating glass bar pinned correctly and — crucially — lifts it above
        // the keyboard when the address field is focused, instead of letting it run off-screen.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showTabs) { TabSwitcherView(tabs: tabs) }
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        .alert(L("No readable article on this page."), isPresented: $showReaderUnavailable) {
            Button(L("Done"), role: .cancel) {}
        }
        // Fire button (DuckDuckGo-style): one confirmed tap burns tabs + website data + favicons.
        .confirmationDialog("Close all tabs and clear website data?",
                            isPresented: $showBurnConfirm, titleVisibility: .visible) {
            Button(L("Close Tabs & Clear Data"), role: .destructive) {
                withAnimation(.smooth) { tabs.burn() }
                syncEditing()
            }
        } message: {
            Text("Closes every tab (including private) and erases cookies, caches, and site data. Bookmarks and history are kept.")
        }
        // Non-web scheme (tel:, mailto:, app link…) → never leave the app silently.
        .alert("Open in another app?", isPresented: externalOpenPresented) {
            Button(L("Cancel"), role: .cancel) { active.pendingExternalURL = nil }
            Button(L("Open")) { active.confirmExternalOpen() }
        } message: {
            Text(active.pendingExternalURL?.absoluteString ?? "")
        }
        // HTTPS-Only upgrade failed → explicit consent before an unencrypted load.
        .alert("Site doesn't support HTTPS", isPresented: httpFallbackPresented) {
            Button(L("Go Back"), role: .cancel) { active.httpFallbackURL = nil }
            Button(L("Use HTTP")) { active.continueWithHTTP() }
        } message: {
            Text("“\(active.httpFallbackURL?.host ?? "This site")” couldn't be loaded securely. Load it over an unencrypted connection just for this session?")
        }
        .onAppear {
            syncEditing()
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let q = env["SEARXLY_DEMO_QUERY"], !q.isEmpty {
                let scope = SearchScope(rawValue: env["SEARXLY_DEMO_SCOPE"] ?? "") ?? .web
                active.runSearch(q, scope: scope)
                syncEditing()
            }
            if let raw = env["SEARXLY_DEMO_URL"], let url = URL(string: raw) {
                // Loads a real page on launch — exercises the full visit path (history recording,
                // favicon capture) without UI driving.
                active.load(url)
                syncEditing()
            }
            if env["SEARXLY_DEMO_FOCUS"] == "1" {
                // REAL first-responder focus — used to verify focus is RETAINED (i.e. the field doesn't
                // get rebuilt and drop the keyboard). If this state is stable, typing works.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addressFocused = true }
                // Set bound text AFTER focus settles (post the focus onChange that clears it) to prove
                // the field renders typed text while focused + keyboard up.
                if let text = env["SEARXLY_DEMO_TEXT"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { editingText = text }
                }
            }
            if env["SEARXLY_DEMO_APPEARANCE"] == "focused" {
                // Force only the focused *look* (no real keyboard) for deterministic screenshots.
                debugForceFocused = true
            }
            if env["SEARXLY_DEMO_SEED"] == "1" { seedDemoLibrary() }
            if let raw = env["SEARXLY_DEMO_SECOND_URL"], let url = URL(string: raw) {
                // A second tab with a real page — populates the tab grid for headless screenshots.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { tabs.newTab(url: url) }
            }
            if env["SEARXLY_DEMO_COLLAPSE"] == "1" {
                // simctl can't send scroll gestures — force the minimized-chrome look instead.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { active.debugForceCollapsed() }
            }
            if env["SEARXLY_DEMO_SWIPE"] == "1" {
                // simctl can't do a fluid drag — load two pages, then park the gesture mid-swipe so the
                // next tab's live preview sliding in is screenshottable.
                active.load(URL(string: "https://en.wikipedia.org/wiki/Tiger")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    _ = tabs.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Lion")!)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { tabs.switchToPrevious() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { dragX = -175 }
            }
            switch env["SEARXLY_DEMO_PANEL"] {
            case "settings":
                showSettings = true
            case "library":
                seedDemoLibrary()
                showLibrary = true
            case "tabs":
                // Late enough for demo pages to load so the grid shows real snapshots.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { openTabs() }
            case "pageinfo":
                // Pair with SEARXLY_DEMO_URL; opens once the page has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { showPageInfo = true }
            case "summary":
                // Pair with SEARXLY_DEMO_URL (+ SEARXLY_FAKE_AI=1 in the simulator).
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { showSummary = true }
            case "reader":
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { openReader() }
            case "downloads":
                DownloadManager.shared.seedDemo()
                showDownloads = true
            case "reading":
                ReadingListStore.shared.seedDemo()
                libraryTab = .reading
                showLibrary = true
            default:
                break
            }
            #endif
        }
        .background { keyboardShortcuts }
        .overlay { privacySnapshotCover }
        .onAppear { consumePendingIntents() }
        .onChange(of: intentRouter.pendingSearch) { consumePendingIntents() }
        .onChange(of: intentRouter.pendingPrivateTab) { consumePendingIntents() }
        .onChange(of: intentRouter.pendingNewSearch) { consumePendingIntents() }
        .onChange(of: intentRouter.pendingReopenLast) { consumePendingIntents() }
        .onChange(of: intentRouter.pendingURL) { consumePendingIntents() }
        .onChange(of: intentRouter.pendingDownloads) { consumePendingIntents() }
        .onChange(of: active.id) { syncEditing() }
        .onChange(of: active.displayText) { if !addressFocused { syncEditing() } }
        // A download just started → surface the Downloads sheet (Safari's downloads popover).
        .onChange(of: downloads.startedGeneration) { showDownloads = true }
        .onChange(of: addressFocused) { _, focused in
            editingText = focused ? active.editText : active.displayText
            if focused { active.expandChrome() }
        }
        // Publish the current page for Handoff so it can be picked up on the Mac (or any device
        // signed into the same iCloud account). Never for private tabs or non-web content —
        // `handoffURL` is nil there and the activity goes inactive.
        .userActivity(NSUserActivityTypeBrowsingWeb, isActive: handoffURL != nil) { activity in
            guard let url = handoffURL else { return }
            activity.webpageURL = url
            activity.title = active.pageTitle.isEmpty ? url.absoluteString : active.pageTitle
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPrediction = false
        }
        // A tapped Spotlight bookmark hands us its URL → open it in a new tab.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let url = URL(string: id) {
                intentRouter.pendingURL = url
            }
        }
        // searxly:// deep links (Home Screen widgets, Share extension, Shortcuts) → the browser.
        .onOpenURL { handleDeepLink($0) }
    }

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
                isPrivate: active.isPrivate
            )
        case .results:
            SearchResultsView(model: active)
        case .web:
            // The page runs UNDER the floating glass bar (Safari): the whole web-mode stack
            // ignores the bar's safe-area inset (the modifier must sit on the OUTERMOST view of
            // the branch — an inner child can't outgrow its already-inset parent) and the scroll
            // view compensates with a content inset, so there's never an opaque band.
            webContent
        }
    }

    private var webContent: some View {
        ZStack(alignment: .top) {
            WKWebViewRepresentable(webView: active.webView)
                .id(active.id)
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
        .ignoresSafeArea(.container, edges: .bottom)
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
            tabs.newTab(isPrivate: true)
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
    }

    /// Hardware-keyboard shortcuts (iPad / Magic Keyboard), Safari-style. Hidden zero-size
    /// buttons register their key equivalents without appearing in the UI.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { tabs.newTab(); syncEditing() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") { tabs.newTab(isPrivate: true); syncEditing() }
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
        if scenePhase != .active && tabs.hasPrivateTabs {
            ZStack {
                Brand.bg.ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .scaledFont(size: 26, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                    Text("Private")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Bottom bar (Safari-style floating Liquid Glass card)

    private var bottomBar: some View {
        VStack(spacing: barCollapsed ? 0 : 9) {
            HStack(spacing: 10) {
                addressPill
                if barFocused {
                    Button(L("Cancel")) { addressFocused = false; debugForceFocused = false }
                        .font(.callout)
                        .foregroundStyle(Brand.text)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Hidden while focused (keyboard up) and while minimized by scrolling. Structural branches
            // around the TOOLBAR are fine — never around the address TextField.
            if !barFocused && !barCollapsed {
                toolbarRow
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, barCollapsed ? 8 : 11)
        .padding(.vertical, barCollapsed ? 5 : 10)
        // ONE stable surface in both states — a tinted, rounded Liquid Glass card. It must never switch
        // background *type* by focus: doing so rebuilds the TextField inside and drops the keyboard.
        // Rounded (never flush) means no hard rim lines either.
        .glassEffect(.regular.tint(barGlassTint), in: .rect(cornerRadius: barCollapsed ? 20 : 26))
        .padding(.horizontal, barCollapsed ? 72 : 9)
        .padding(.bottom, 4)
        .animation(.smooth(duration: 0.28), value: barFocused)
        .animation(.smooth(duration: 0.24), value: barCollapsed)
    }

    /// Slight darkening of the Liquid Glass dock — eased back from the previous (too-dark) value.
    /// Private tabs get a noticeably deeper tint so the mode is always visible at a glance.
    private var barGlassTint: Color {
        if active.isPrivate {
            return colorScheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.16)
        }
        return colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.05)
    }

    // MARK: - Interactive tab swipe (Safari-style)

    /// The tab to the left / right of the active one (nil at the ends).
    private var prevTab: BrowserModel? {
        let i = tabs.activeIndex
        return i > 0 ? tabs.tabs[i - 1] : nil
    }
    private var nextTab: BrowserModel? {
        let i = tabs.activeIndex
        return i < tabs.tabs.count - 1 ? tabs.tabs[i + 1] : nil
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
        HStack(spacing: 8) {
            if !barFocused {
                // On web pages the lock is tappable → Page Info (security, shields, site settings).
                Button {
                    if active.content == .web { showPageInfo = true }
                } label: {
                    Image(systemName: pillIcon)
                        .scaledFont(size: 13)
                        .foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(active.content != .web)
                .accessibilityLabel(active.content == .web ? "Page info" : "Search")
            }

            TextField(L("Search or enter address"), text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: barCollapsed ? 13 : 17))
                .foregroundStyle(Brand.text)
                .tint(Brand.text)
                .focused($addressFocused)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                .multilineTextAlignment(barFocused ? .leading : .center)
                .onSubmit {
                    active.submit(editingText)
                    addressFocused = false
                }

            if !barFocused && active.content == .web && !barCollapsed {
                if active.pageBlockedCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "shield.fill")
                            .scaledFont(size: 10, weight: .medium)
                        Text("\(active.pageBlockedCount)")
                            .scaledFont(size: 11, weight: .semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(Brand.textTertiary)
                    .accessibilityLabel("\(active.pageBlockedCount) trackers blocked on this page")
                }
                Button { active.reloadOrStop() } label: {
                    Image(systemName: active.isLoading ? "xmark" : "arrow.clockwise")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(Brand.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active.isLoading ? "Stop" : "Reload")
            }

            if barFocused && !editingText.isEmpty {
                Button { editingText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Brand.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, barCollapsed ? 12 : 15)
        .padding(.vertical, barCollapsed ? 7 : 11)
        // Recessed field inside the glass card (Safari look) — not a second glass layer.
        .background(Capsule().fill(Brand.text.opacity(barFocused ? 0.11 : 0.07)))
        .overlay(Capsule().strokeBorder(Brand.text.opacity(barFocused ? 0.10 : 0.06), lineWidth: 0.5))
        // Safari's signature: swipe the address pill sideways to switch tabs (interactive — the page
        // tracks your finger), up for the grid. The mask (not a structural branch — see the typing-bug
        // rule) disables it entirely while editing, so a drag can never fight the TextField.
        .simultaneousGesture(barDrag, including: barFocused ? .none : .all)
    }

    private var pillIcon: String {
        if active.isPrivate { return "hand.raised.fill" }
        return active.content == .web ? "lock.fill" : "magnifyingglass"
    }

    private var toolbarRow: some View {
        HStack(spacing: 0) {
            historyNavButton("chevron.backward", enabled: active.canGoBack,
                             items: active.backHistory) { active.goBack() }
                .accessibilityLabel("Back")
            Spacer()
            historyNavButton("chevron.forward", enabled: active.canGoForward,
                             items: active.forwardHistory) { active.goForward() }
                .accessibilityLabel("Forward")
            Spacer()
            pageMenu
                .accessibilityLabel("Page options")
            Spacer()
            navButton("book") { libraryTab = .bookmarks; showLibrary = true }
                .accessibilityLabel("Bookmarks and history")
            Spacer()
            tabsButton
                .accessibilityLabel("Tabs, \(tabs.tabs.count) open")
        }
        .padding(.horizontal, 6)
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

    /// Tap = tab overview; long-press = quick tab actions (Safari behavior).
    private var tabsButton: some View {
        Menu {
            Button { tabs.newTab(); syncEditing() } label: {
                Label(L("New Tab"), systemImage: "plus.square")
            }
            Button { tabs.newTab(isPrivate: true); syncEditing() } label: {
                Label(L("New Private Tab"), systemImage: "hand.raised")
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
            if tabs.tabs.count > 1 {
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
                            Label(L("Summarize Page"), systemImage: "sparkles")
                        }
                        Button { showPageChat = true } label: {
                            Label(L("Ask About This Page"), systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                }

                Section(L("View")) {
                    Button { openReader() } label: {
                        Label(L("Reader"), systemImage: "doc.plaintext")
                    }
                    Button { active.findOnPage() } label: {
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
                Button { tabs.newTab(isPrivate: true); syncEditing() } label: {
                    Label(L("New Private Tab"), systemImage: "hand.raised")
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
            Text("\(tabs.tabs.count)")
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
