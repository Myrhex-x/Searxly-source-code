//
//  ContentView+Layout.swift
//  Searxly
//
//  Sidebar layout and address-bar suggestions overlay for ContentView.
//

import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

extension ContentView {
    // MARK: - Slim header suggestions

    var slimSuggestionsVisible: Bool {
        // Intentionally NOT gated on isAddressBarFocused: clicking a suggestion blurs the field, and if
        // the panel unmounted on that blur the click would be cancelled mid-press. BrowserState clears
        // the suggestions on blur (after a short grace period) instead, so the panel still goes away.
        !isPureHomeState
            && browserState.shouldShowSuggestionsPanel
            && slimAddressBarFrame.width > 0
            && slimAddressBarFrame.height > 0
    }

    @ViewBuilder
    var slimHeaderSuggestionsOverlay: some View {
        if slimSuggestionsVisible {
            AddressBarSuggestionsView(
                suggestions: browserState.suggestions,
                selectedIndex: browserState.suggestionsSelectedIndex,
                isLoading: browserState.suggestionsIsLoading,
                glassEnabled: glassEnabled,
                toolbarMaterial: toolbarMaterial,
                barCornerRadius: 11,
                maxWidth: slimAddressBarFrame.width,
                onSelect: { suggestion in
                    browserState.selectSuggestion(suggestion)
                },
                onDismiss: {
                    browserState.dismissSuggestionsPanel()
                }
            )
            .frame(width: slimAddressBarFrame.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .offset(
                x: slimAddressBarFrame.minX,
                y: slimAddressBarFrame.maxY + 6
            )
            .zIndex(500)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.14), value: slimSuggestionsVisible)
        }
    }

    // MARK: - Auto-hide vertical tabs (Arc-style)

    /// Expanded (full labels) while auto-hide is on. Resting state is the compact peeker rail.
    var isSidebarAutoHideExpanded: Bool {
        sidebarAutoHide && (isSidebarHoverRevealed || isSidebarKeyboardPinned)
    }

    /// Expanded width used when the auto-hide overlay is showing.
    var autoHideSidebarWidth: CGFloat {
        let remembered = browserState.lastExpandedSidebarWidth
        return remembered > BrowserState.collapseThreshold
            ? remembered
            : BrowserState.defaultExpandedWidth
    }

    /// Compact peeker width (icon rail). Slightly roomier when floating so tiles aren't crushed by
    /// the panel's inset padding.
    var peekerRailWidth: CGFloat {
        floatingSidebarActive ? BrowserState.peekerWidthFloating : BrowserState.railWidth
    }

    /// Layout width reserved for the sidebar in the main HStack.
    /// Auto-hide reserves peeker when resting; when expanded/pinned it reserves the full width so
    /// search results and page content shift aside instead of sitting under the overlay panel.
    var sidebarLayoutWidth: CGFloat {
        if sidebarAutoHide {
            return isSidebarAutoHideExpanded ? autoHideSidebarWidth : peekerRailWidth
        }
        return browserState.sidebarWidth
    }

    /// Live width of the auto-hide overlay panel (peeker ↔ expanded).
    var autoHidePanelWidth: CGFloat {
        isSidebarAutoHideExpanded ? autoHideSidebarWidth : peekerRailWidth
    }

    func revealSidebarForAutoHide() {
        sidebarHoverRevealTask?.cancel()
        sidebarHoverRevealTask = nil
        sidebarAutoHideTask?.cancel()
        sidebarAutoHideTask = nil
        guard sidebarAutoHide else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            isSidebarHoverRevealed = true
        }
    }

    /// Slight dwell before peeker → expanded so a quick tab-icon click doesn't flash the full list open.
    func scheduleSidebarHoverReveal() {
        guard sidebarAutoHide else { return }
        if isSidebarAutoHideExpanded {
            cancelSidebarAutoHide()
            isSidebarHoverRevealed = true
            return
        }
        sidebarHoverRevealTask?.cancel()
        sidebarAutoHideTask?.cancel()
        sidebarAutoHideTask = nil
        sidebarHoverRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                isSidebarHoverRevealed = true
            }
        }
    }

    func scheduleSidebarAutoHide() {
        guard sidebarAutoHide, !isSidebarKeyboardPinned else { return }
        sidebarHoverRevealTask?.cancel()
        sidebarHoverRevealTask = nil
        sidebarAutoHideTask?.cancel()
        sidebarAutoHideTask = Task { @MainActor in
            // Long enough that moving across the panel, or opening a context menu, doesn't
            // flicker the expanded sidebar closed mid-gesture.
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                isSidebarHoverRevealed = false
            }
        }
    }

    func cancelSidebarAutoHide() {
        sidebarHoverRevealTask?.cancel()
        sidebarHoverRevealTask = nil
        sidebarAutoHideTask?.cancel()
        sidebarAutoHideTask = nil
    }

    func hideSidebarForAutoHide() {
        cancelSidebarAutoHide()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            isSidebarHoverRevealed = false
            isSidebarKeyboardPinned = false
        }
    }

    /// ⌘S / View ▸ Toggle Sidebar. Auto-hide: pin expanded / collapse to peeker. Classic: rail ↔ expanded.
    /// (Manual chevron buttons were removed — expand is hover + this shortcut only.)
    func handleToggleSidebar() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
            if sidebarAutoHide {
                if isSidebarKeyboardPinned || isSidebarHoverRevealed {
                    isSidebarHoverRevealed = false
                    isSidebarKeyboardPinned = false
                } else {
                    isSidebarKeyboardPinned = true
                    isSidebarHoverRevealed = true
                }
            } else {
                browserState.toggleSidebarCollapse()
            }
        }
    }

    // MARK: - Layout

    /// Left sidebar (Arc-style) layout is the ONLY supported layout.
    /// Now reads most state from BrowserState (refactor). Still owns the reduce glass @AppStorage
    /// and FocusState for the address bar (view concerns).
    ///
    /// Two modes (Settings → Appearance → Tabs, same for base + Maximum):
    /// - **Auto-hide (default):** resting state is a compact peeker rail (tab icons + new tab).
    ///   Hover the peeker (or ⌘S) to expand; content shifts aside so results aren't covered.
    ///   Collapses back when the pointer leaves (⌘S pins expanded). No manual expand chevron.
    /// - **Always show:** classic rail / expanded list via ⌘S (no chevron button).
    /// Free drag-to-resize has been removed (it was causing persistent lag, glitches, and bad sizes).
    ///
    /// - For !isPureHomeState (search results or open webpage) we render a single slim header row that places
    ///   a compact AddressBar to the *left* of the RightToolbarControls button cluster. This removes the
    ///   previous separate AddressBar strip, giving the web content / search results list (the focus area)
    ///   significantly more vertical space.
    /// - Pure home keeps its hero centered AddressBar (inside mainContentArea) + the right controls row.
    @ViewBuilder
    var tabSidebarPanel: some View {
        // Auto-hide: peeker (collapsed) when resting, full list when expanded/pinned.
        // Classic: follows BrowserState rail ↔ expanded.
        let collapsed = sidebarAutoHide
            ? !isSidebarAutoHideExpanded
            : browserState.isSidebarCollapsed
        let width = sidebarAutoHide ? autoHidePanelWidth : browserState.sidebarWidth

        SidebarTabList(
            tabs: $browserState.tabs,
            selectedTabID: $browserState.selectedTabID,
            glassEnabled: glassEnabled,
            toolbarMaterial: toolbarMaterial,
            isFloating: floatingSidebarActive,
            sidebarWidth: width,
            isCollapsed: collapsed,
            isPeeker: sidebarAutoHide && !isSidebarAutoHideExpanded,
            newTabAction: newTab,
            newPrivateTabAction: newPrivateTab,
            closeTabAction: closeTab,
            closeAllTabsAction: closeAllTabs,
            pinTabAction: { tab in
                tab.isPinned.toggle()
                guard let idx = browserState.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                let removed = browserState.tabs.remove(at: idx)
                // Always insert at the boundary between pinned and regular tabs.
                // Pinned: moves to end of pinned group. Unpinned: moves to start of regular group.
                let insertAt = browserState.tabs.filter { $0.isPinned }.count
                browserState.tabs.insert(removed, at: insertAt)
            },
            duplicateTabAction: { tab in browserState.duplicateTab(tab) },
            muteTabAction: { tab in
                // @Observable BrowserTab → the sidebar mute icon refreshes on its own (no array hack).
                tab.isMuted.toggle()
                tab.applyMute()
            },
            forgetDomainAction: forgetDomainInSidebar,
            reopenClosedTabAction: browserState.recentlyClosedSnapshots.isEmpty ? nil : { browserState.reopenLastClosedTab() },
            hasClosedTabs: !browserState.recentlyClosedSnapshots.isEmpty,
            bookmarkTabAction: { tab in browserState.bookmarkTab(tab) },
            customCategories: browserState.customTabCategories,
            canAddCategory: browserState.customTabCategories.count < BrowserState.maxCustomCategories,
            moveTabToCategory: { tab, categoryID in browserState.moveTab(tab, toCategory: categoryID) },
            reorderTabBefore: { tab, target in browserState.moveTab(tab, before: target) },
            addCategoryAction: { name, tabToMove in
                if let category = browserState.addCategory(named: name), let tabToMove {
                    browserState.moveTab(tabToMove, toCategory: category.id)
                }
            },
            renameCategoryAction: { category, name in browserState.renameCategory(category, to: name) },
            deleteCategoryAction: { category in browserState.deleteCategory(category) },
            bookmarks: browserState.bookmarks,
            onOpenBookmark: { bookmark in
                if let url = URL(string: bookmark.url) { browserState.openURLPreferringCurrentTab(url) }
            },
            onRemoveBookmark: { bookmark in
                browserState.bookmarks.removeAll { $0.id == bookmark.id }
            },
            showingSettings: $browserState.showingSettings,
            showingWallet: $browserState.showingWallet,
            showingBookmarks: $browserState.showingBookmarks,
            showingFullHistory: $browserState.showingFullHistory,
            showingDownloads: $browserState.showingDownloads
        )
        .modifier(FloatingSidebarChrome(
            enabled: floatingSidebarActive,
            glassEnabled: glassEnabled,
            scheme: resolvedColorScheme,
            compact: sidebarAutoHide && !isSidebarAutoHideExpanded
        ))
    }

    var sidebarLayout: some View {
        ZStack(alignment: .leading) {
        HStack(spacing: 0) {
            // Classic mode: sidebar participates in the HStack layout (rail or expanded).
            // Auto-hide mode: reserve peeker when resting, full width when expanded so search
            // results / web content shift right instead of sitting under the overlay panel.
            if sidebarAutoHide {
                Color.clear
                    .frame(width: sidebarLayoutWidth)
                    .accessibilityHidden(true)
            } else {
                tabSidebarPanel
                    .frame(width: browserState.sidebarWidth)
            }

            VStack(spacing: 0) {
                // Right column content (slim header on results/web + main content, or home hero content).
                // The ZStack is used to hoist suggestions above the web content / results without
                // affecting their layout (the inner VStack keeps its normal size).
                ZStack(alignment: .topLeading) {
                    if isPureHomeState {
                        HomeAmbientBackground(
                            glassEnabled: glassEnabled,
                            homeStarsEnabled: homeStarsEnabled
                        )
                    }

                    Color.clear
                        .onChange(of: isAddressBarFocused) { _, focused in
                            updateSuggestionsFromFocus()
                            // Left the bar without navigating → drop any half-typed edit and show the live
                            // page URL again (Safari behavior). The focused-guard on the webCurrentURL sync
                            // means edits are otherwise preserved, so this is the only place they revert.
                            if !focused && browserState.showingWebContent {
                                browserState.syncAddressBarWithWebURL()
                            }
                        }
                    VStack(spacing: 0) {
                        BrowserHeaderView(
                            isPureHomeState: isPureHomeState,
                            glassEnabled: glassEnabled,
                            toolbarMaterial: toolbarMaterial,
                            searchText: $browserState.searchText,
                            isAddressBarFocused: $isAddressBarFocused,
                            showingWebContent: browserState.showingWebContent,
                            browserState: browserState,
                            onSubmit: { submitFromAddressBar() },
                            activeWebView: browserState.activeWebView,
                            canGoBack: browserState.canGoBack,
                            canGoForward: browserState.canGoForward,
                            bookmarks: $browserState.bookmarks,
                            webPageTitle: $browserState.webPageTitle,
                            showingBookmarks: $browserState.showingBookmarks,
                            showingFullHistory: $browserState.showingFullHistory,
                            showingDownloads: $browserState.showingDownloads,
                            showingKeyboardShortcuts: $browserState.showingKeyboardShortcuts,
                            onShowFind: { browserState.showFindInPage() },
                            onBookmarkCurrentPage: { browserState.bookmarkCurrentPage() },
                            onGoBack: { browserState.goBack() },
                            onGoForward: { browserState.goForward() },
                            currentWebDomain: browserState.currentWebDomain,
                            hasPasswordFieldOnPage: browserState.currentPageHasPasswordField,
                            isLikelySignupForm: browserState.currentPageIsLikelyPasswordCreation,
                            onGeneratePasswordForPage: passwordVault.isSuggestPasswordsActive ? {
                                browserState.generateAndFillPasswordOnCurrentPage()
                            } : nil,
                            onSaveLoginFromPage: passwordVault.isOfferToSaveActive ? {
                                presentSaveLoginSheet()
                            } : nil,
                            onFillLogin: passwordVault.isAutofillActive ? { domain, username, password in
                                browserState.fillCurrentPageWithLogin(username: username, password: password)
                                if let entry = passwordVault.entries(forDomain: domain).first(where: { $0.username == username }) {
                                    passwordVault.markEntryUsed(id: entry.id)
                                }
                            } : nil,
                            onFillTOTP: passwordVault.isAutofillActive ? { code in
                                browserState.fillCurrentPageWithTOTP(code)
                            } : nil
                        )

                        if bookmarksBarVisible && !browserState.bookmarks.isEmpty {
                            BookmarksBarView(
                                bookmarks: browserState.bookmarks,
                                glassEnabled: glassEnabled,
                                onOpen: { url in browserState.openURLPreferringCurrentTab(url) },
                                onOpenInNewTab: { url in browserState.openExternalURL(url) },
                                onRemove: { bookmark in
                                    browserState.bookmarks.removeAll { $0.id == bookmark.id }
                                }
                            )
                        }

                        mainContentArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .simultaneousGesture(
                                TapGesture()
                                    .onEnded {
                                        // Dismiss open suggestions (including while loading).
                                        if browserState.shouldShowSuggestionsPanel {
                                            dismissSuggestionsAndBlur()
                                            return
                                        }
                                        // On results/web, tap the content area to leave the slim header bar.
                                        // Skip on pure home — that gesture steals focus from the hero search bar.
                                        if isAddressBarFocused && !isPureHomeState {
                                            dismissSuggestionsAndBlur()
                                        }
                                    }
                            )
                    }

                    slimHeaderSuggestionsOverlay
                }
                .coordinateSpace(name: "mainColumn")
                .onPreferenceChange(AddressBarFramePreferenceKey.self) { frame in
                    slimAddressBarFrame = frame
                }
                    .sheet(item: $browserState.selectedImageForPreview) { result in
                        // Uses the new modular MediaPreviewSheet (Views/SearchResults/) from the 2026 SERP redesign.
                        // Supports both images and videos with correct proxy for high-quality previews.
                        MediaPreviewSheet(
                            result: result,
                            isVideo: browserState.currentSearchCategory == "videos",
                            onOpenPage: {
                                if let url = URL(string: result.url) { loadInWebView(url) }
                                browserState.selectedImageForPreview = nil
                            },
                            proxyBaseURL: browserState.lastSearchInstanceURL ?? browserState.searxInstances.first?.url
                        )
                    }
                    // Focus transfer: when we leave pure home (hero bar) because the user submitted a search,
                    // the hero AddressBar is removed from the tree and the slim header bar appears in its place.
                    // Re-assert focus on the (now visible) slim bar after a tiny delay so the user can
                    // immediately type a refinement or new query without having to click or press ⌘L again.
                    .onChange(of: isPureHomeState) { wasPure, isPure in
                        if wasPure && !isPure && isAddressBarFocused {
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(110))
                                focusAddressBar()
                            }
                        }
                    }
            }
            .background {
                if !isPureHomeState {
                    AdaptiveChrome.appCanvas(resolvedColorScheme, glassEnabled: glassEnabled)
                }
            }

            // MARK: - Global browser keyboard shortcuts (Safari-like)
            // These are always available (even when web nav buttons are not visible in the header).
            // We use tiny hidden buttons so the shortcuts are registered without affecting layout.
            Group {
                // Reload (⌘R) — works on web pages or to re-trigger search in some cases
                Button("Reload") {
                    if browserState.showingWebContent {
                        browserState.reload()
                    } else if !browserState.searchResults.isEmpty {
                        // Re-run the last search if on results
                        performSearchOrLoadInWebKit()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Back / Forward
                Button("Back") { browserState.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                Button("Forward") { browserState.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Focus / select address bar (⌘L) — works in header or home
                Button("Focus Address Bar") {
                    focusAddressBar()
                }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Close current tab (⌘W)
                Button("Close Tab") {
                    browserState.closeCurrentTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Find in page (⌘F) is now a real menu command (SearxlyApp → .findInPageRequested)
                // so it fires even when a web page is focused. No hidden button needed here.

                // Stop loading (⌘.)
                Button("Stop Loading") {
                    if browserState.showingWebContent {
                        browserState.stopLoading()
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Bookmark current page (⌘D) — also available via toolbar when on web
                Button("Bookmark Current Page") {
                    browserState.bookmarkCurrentPage()
                }
                .keyboardShortcut("d", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // Zoom is handled by real View-menu commands (see SearxlyApp + ZoomCommandReceiver),
                // because a focused WKWebView shadows hidden-button keyboard shortcuts. The receiver
                // turns those menu commands into page-zoom calls.
                ZoomCommandReceiver(browserState: browserState)

                // Print the current web page (⌘P)
                Button("Print…") { browserState.printCurrentPage() }
                    .keyboardShortcut("p", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // New Tab (⌘T) / New Private Tab (⌘⇧T) are real File-menu commands (SearxlyApp →
                // .newTabRequested / .newPrivateTabRequested) so they fire even when a web page is
                // focused, and they focus the address bar on arrival. No hidden buttons needed here.

                Button("Reopen Closed Tab") { browserState.reopenLastClosedTab() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                Button("Mute Tab") {
                    guard let tab = browserState.tabs.first(where: { $0.id == browserState.selectedTabID }) else { return }
                    tab.isMuted.toggle()
                    tab.applyMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                // ⌘1–8: jump to tab by position; ⌘9 is always the LAST tab (the standard
                // Safari/Chrome contract — "take me to the end" regardless of tab count).
                ForEach(Array(1...9), id: \.self) { i in
                    Button("Tab \(i)") {
                        let ts = browserState.tabs
                        guard !ts.isEmpty else { return }
                        let index = i == 9 ? ts.count - 1 : i - 1
                        guard index < ts.count else { return }
                        browserState.selectedTabID = ts[index].id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }

                // ⌃Tab / ⌃⇧Tab: cycle through tabs
                Button("Next Tab") {
                    let ts = browserState.tabs
                    guard !ts.isEmpty else { return }
                    let idx = ts.firstIndex(where: { $0.id == browserState.selectedTabID }) ?? 0
                    browserState.selectedTabID = ts[(idx + 1) % ts.count].id
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                Button("Previous Tab") {
                    let ts = browserState.tabs
                    guard !ts.isEmpty else { return }
                    let idx = ts.firstIndex(where: { $0.id == browserState.selectedTabID }) ?? 0
                    browserState.selectedTabID = ts[(idx - 1 + ts.count) % ts.count].id
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }

            // Auto-hide: peeker rail (resting) or expanded list as an overlay (base + Maximum).
            // Hover peeker → expand after a short dwell; leave → collapse (unless ⌘S-pinned).
            // Layout spacer tracks panel width so content is never covered.
            if sidebarAutoHide {
                tabSidebarPanel
                    .frame(width: autoHidePanelWidth)
                    .frame(maxHeight: .infinity)
                    .onHover { hovering in
                        if hovering {
                            scheduleSidebarHoverReveal()
                        } else {
                            scheduleSidebarAutoHide()
                        }
                    }
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isSidebarAutoHideExpanded)
        .onChange(of: sidebarAutoHide) { _, enabled in
            // Switching modes shouldn't leave a ghost pin/reveal from the previous mode.
            cancelSidebarAutoHide()
            isSidebarHoverRevealed = false
            isSidebarKeyboardPinned = false
            if !enabled {
                // Landing in classic mode: start from the expanded list so the peeker→rail
                // transition doesn't strand the user on a narrow strip they didn't ask for.
                if browserState.sidebarWidth <= BrowserState.collapseThreshold {
                    browserState.setSidebarWidth(BrowserState.defaultExpandedWidth)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let divider = AdaptiveChrome.divider(resolvedColorScheme)
                // Auto-hide reserves peeker width in-flow; classic uses the live sidebar width.
                let sidebarW = sidebarLayoutWidth
                let headerH = AdaptiveChrome.slimToolbarRowHeight
                let isExpanded = sidebarAutoHide
                    ? false
                    : !browserState.isSidebarCollapsed

                // Floating sidebar: the card's own rounded border IS the separation, so the sidebar
                // edge divider disappears and the header divider stops at the content column.
                // Auto-hide peeker/overlay also uses the floating card (or classic panel) as its own edge.
                let floating = floatingSidebarActive || sidebarAutoHide

                if isPureHomeState {
                    if !floating && sidebarW > 0 {
                        Rectangle()
                            .fill(divider)
                            .frame(width: 1, height: geo.size.height)
                            .offset(x: sidebarW - 1)
                    }
                } else {
                    Rectangle()
                        .fill(divider)
                        .frame(
                            width: (isExpanded && !floating) ? geo.size.width : geo.size.width - sidebarW,
                            height: 1
                        )
                        .offset(x: (isExpanded && !floating) ? 0 : sidebarW, y: headerH - 1)

                    if !floating && sidebarW > 0 {
                        Rectangle()
                            .fill(divider)
                            .frame(
                                width: 1,
                                height: isExpanded ? max(0, geo.size.height - headerH) : geo.size.height
                            )
                            .offset(x: sidebarW - 1, y: isExpanded ? headerH : 0)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        // Drag a local file (an .html file, image, PDF, …) from Finder onto the window to open it in a
        // new tab. Registered for file URLs only, so it never conflicts with the sidebar's tab-reorder
        // drops (which carry plain text). Finder file drags come with a sandbox grant, so WebKit can read
        // the dropped file.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }

    /// Moves keyboard focus to the address bar, first resigning any first responder the active web view
    /// (or a focused page input) is holding. Without the resign, SwiftUI can't take key focus off a live
    /// WKWebView, leaving the bar visually focused but non-editable — the "can't type in the URL bar once
    /// a page is open" bug. Mirrors `AddressBar.focusField()`, which handles the in-bar click path.
    func focusAddressBar() {
        resignWebViewFirstResponder()
        isAddressBarFocused = true
    }

    /// Releases whatever the live web view (or a focused page input) holds as the window's first
    /// responder. Prefers the active web view's own window; falls back to the key window for the case
    /// where that view has already been detached — right after a tab swap, `activeWebView` is the new
    /// tab's not-yet-mounted view and its `window` is nil, so without the fallback the OUTGOING page
    /// would quietly keep key focus.
    func resignWebViewFirstResponder() {
        let window = browserState.activeWebView.window ?? NSApp.keyWindow
        _ = window?.makeFirstResponder(nil)
    }

    /// Opens a viewable local file dragged onto the window (see the `.onDrop` above). Non-viewable files
    /// (archives, binaries, …) are ignored so a stray drop doesn't spawn a blank tab. The URL is opened on
    /// the main actor via `openLocalFileURL`, which retains the drag's sandbox grant for the tab.
    func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let u = item as? URL {
                url = u
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            guard let fileURL = url, fileURL.isFileURL,
                  ContentView.isViewableLocalFile(fileURL) else { return }
            DispatchQueue.main.async {
                browserState.openLocalFileURL(fileURL)
            }
        }
        return true
    }

    /// Whether a dropped local file is something the web view can display inline (so opening it makes
    /// sense). HTML is the primary target; images / PDF / SVG / plain-text formats are included because
    /// WebKit renders them too. Anything else is left for the user to handle in Finder.
    static func isViewableLocalFile(_ url: URL) -> Bool {
        let viewable: Set<String> = [
            "html", "htm", "xhtml", "shtml", "svg",
            "pdf", "txt", "xml", "json",
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"
        ]
        return viewable.contains(url.pathExtension.lowercased())
    }
}

// AddressBar has been extracted to Views/Components/AddressBar.swift (compact/fluid redesign for sidebar search use).

// (SearchResultCard definition removed — now in Components/SearchResultCard.swift after monster refactor.)

// MARK: - Floating sidebar chrome

/// The macOS-26-style floating tab sidebar (Settings → Appearance → Effects, off by default):
/// the list becomes an inset panel with SUPER-round continuous corners on a frosted glass surface —
/// the look Apple shipped in macOS 26 sidebars and dropped as the default in 27. Monochrome per the
/// Searxly brand: neutral glass (a solid adaptive panel when the user reduces liquid glass), a plain
/// hairline border in place of the edge divider, and a soft neutral shadow. The window's traffic
/// lights land ON the panel's top-left, exactly like the original. Applies ONLY to the tab sidebar.
///
/// `compact` is for the auto-hide peeker rail: tighter corner radius + inset so a narrow icon strip
/// still reads as a premium floating card instead of a crushed full-size panel.
private struct FloatingSidebarChrome: ViewModifier {
    let enabled: Bool
    let glassEnabled: Bool
    let scheme: ColorScheme
    var compact: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                // The shared floating-panel surface (SearxlyFloatingPanel.swift) — same chrome as the
                // SERP knowledge panel, passed the app-resolved scheme so the appearance override wins.
                .searxlyFloatingPanel(
                    cornerRadius: compact ? 14 : 18,
                    scheme: scheme
                )
                // Inset = the float. Peeker uses a tighter inset so 38pt tiles keep breathing room.
                .padding(compact
                    ? EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 5)
                    : EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 8))
                // The gap around the card shows the app canvas, same surface the classic sidebar used.
                .background(Rectangle().fill(AdaptiveChrome.appCanvas(scheme, glassEnabled: glassEnabled)))
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
}
