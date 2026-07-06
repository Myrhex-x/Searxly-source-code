//
//  ContentView+Layout.swift
//  Searxly
//
//  Sidebar layout and address-bar suggestions overlay for ContentView.
//

import SwiftUI
import AppKit
import WebKit

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

    // MARK: - Layout

    /// Left sidebar (Arc-style) layout is the ONLY supported layout.
    /// Now reads most state from BrowserState (refactor). Still owns the reduce glass @AppStorage
    /// and FocusState for the address bar (view concerns).
    ///
    /// Sidebar is toggled between narrow rail and expanded list via the chevron buttons only.
    /// Free drag-to-resize has been removed (it was causing persistent lag, glitches, and bad sizes).
    /// Width is always one of the two canonical values from BrowserState (rail or defaultExpanded).
    ///
    /// - For !isPureHomeState (search results or open webpage) we render a single slim header row that places
    ///   a compact AddressBar to the *left* of the RightToolbarControls button cluster. This removes the
    ///   previous separate AddressBar strip, giving the web content / search results list (the focus area)
    ///   significantly more vertical space.
    /// - Pure home keeps its hero centered AddressBar (inside mainContentArea) + the right controls row.
    var sidebarLayout: some View {
        HStack(spacing: 0) {
            // Sidebar width is driven purely by the toggle (chevron). No more free drag/resizer.
            // We use the canonical rail vs expanded widths from BrowserState for consistent, glitch-free behavior.
            SidebarTabList(
                tabs: $browserState.tabs,
                selectedTabID: $browserState.selectedTabID,
                glassEnabled: glassEnabled,
                toolbarMaterial: toolbarMaterial,
                isFloating: floatingSidebarActive,
                sidebarWidth: browserState.sidebarWidth,
                isCollapsed: browserState.isSidebarCollapsed,
                toggleCollapse: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                        browserState.toggleSidebarCollapse()
                    }
                },
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
                scheme: resolvedColorScheme
            ))
            .frame(width: browserState.sidebarWidth)

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
                        .onChange(of: isAddressBarFocused) {
                            updateSuggestionsFromFocus()
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
                            onSummarizePage: { browserState.summarizeCurrentPageAction() },
                            onShowFind: { browserState.showFindInPage() },
                            onOpenLocalAIChat: { browserState.openLocalAIChat() },
                            onBookmarkCurrentPage: { browserState.bookmarkCurrentPage() },
                            onGoBack: { browserState.goBack() },
                            onGoForward: { browserState.goForward() },
                            currentWebDomain: browserState.currentWebDomain,
                            hasPasswordFieldOnPage: browserState.currentPageHasPasswordField,
                            isLikelySignupForm: browserState.currentPageIsLikelyPasswordCreation,
                            onGeneratePasswordForPage: passwordVault.suggestPasswordsEnabled ? {
                                browserState.generateAndFillPasswordOnCurrentPage()
                            } : nil,
                            onSaveLoginFromPage: passwordVault.offerToSaveEnabled ? {
                                presentSaveLoginSheet()
                            } : nil,
                            onFillLogin: passwordVault.autofillEnabled ? { domain, username, password in
                                browserState.fillCurrentPageWithLogin(username: username, password: password)
                                if let entry = passwordVault.entries(forDomain: domain).first(where: { $0.username == username }) {
                                    passwordVault.markEntryUsed(id: entry.id)
                                }
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
                                isAddressBarFocused = true
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
                    isAddressBarFocused = true
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

                // New Tab / New Private Tab (global, in addition to sidebar buttons)
                Button("New Tab") { newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

                Button("New Private Tab") { newPrivateTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

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
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let divider = AdaptiveChrome.divider(resolvedColorScheme)
                let sidebarW = browserState.sidebarWidth
                let headerH = AdaptiveChrome.slimToolbarRowHeight
                let isExpanded = !browserState.isSidebarCollapsed

                // Floating sidebar: the card's own rounded border IS the separation, so the sidebar
                // edge divider disappears and the header divider stops at the content column.
                let floating = floatingSidebarActive

                if isPureHomeState {
                    if !floating {
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

                    if !floating {
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
private struct FloatingSidebarChrome: ViewModifier {
    let enabled: Bool
    let glassEnabled: Bool
    let scheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                // The shared floating-panel surface (SearxlyFloatingPanel.swift) — same chrome as the
                // SERP knowledge panel, passed the app-resolved scheme so the appearance override wins.
                .searxlyFloatingPanel(scheme: scheme)
                // Inset = the float. Slightly tighter on the trailing edge so the gap to the web
                // content reads intentional rather than like a gutter.
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 8))
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
