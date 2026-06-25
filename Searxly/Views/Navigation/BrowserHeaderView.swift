//
//  BrowserHeaderView.swift
//  Searxly
//
//  Slim header bar (web/SERP) or home toolbar row.
//  Suggestions for the slim bar are hoisted in ContentView, anchored to AddressBarFramePreferenceKey.
//

import SwiftUI
import WebKit

struct BrowserHeaderView: View {
    @Environment(\.colorScheme) private var colorScheme

    let isPureHomeState: Bool
    let glassEnabled: Bool
    let toolbarMaterial: Material

    @Binding var searchText: String
    @FocusState.Binding var isAddressBarFocused: Bool
    let showingWebContent: Bool

    @Bindable var browserState: BrowserState

    let onSubmit: () -> Void

    let activeWebView: WKWebView
    let canGoBack: Bool
    let canGoForward: Bool
    @Binding var bookmarks: [BookmarkItem]
    @Binding var webPageTitle: String
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingKeyboardShortcuts: Bool
    let onToggleReaderMode: () -> Void
    let onShowFind: () -> Void
    let onOpenLocalAIChat: () -> Void
    let onBookmarkCurrentPage: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let currentWebDomain: String?

    let hasPasswordFieldOnPage: Bool
    let isLikelySignupForm: Bool
    let onGeneratePasswordForPage: (() -> Void)?
    let onSaveLoginFromPage: (() -> Void)?
    let onFillLogin: ((String, String, String) -> Void)?

    var body: some View {
        Group {
        if !isPureHomeState {
            HStack(spacing: 8) {
                SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)

                SearxlyTorPill(
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onionHost: browserState.selectedTab?.privacyMode == .onion
                        ? browserState.selectedTab?.currentURL?.host : nil,
                    onNewCircuit: {
                        Task { @MainActor in
                            if await TorManager.shared.newCircuit() {
                                browserState.activeWebView.reload()
                            }
                        }
                    }
                )

                Spacer()

                AddressBar(
                    text: $searchText,
                    isFocused: $isAddressBarFocused,
                    showingWebContent: showingWebContent,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onSubmit: onSubmit,
                    isHero: false,
                    isOnionTab: browserState.selectedTab?.privacyMode == .onion,
                    onSuggestionsArrowDown: {
                        if !browserState.suggestions.isEmpty {
                            browserState.suggestionsSelectedIndex = min(browserState.suggestionsSelectedIndex + 1, browserState.suggestions.count - 1)
                        }
                    },
                    onSuggestionsArrowUp: {
                        if !browserState.suggestions.isEmpty {
                            browserState.suggestionsSelectedIndex = max(browserState.suggestionsSelectedIndex - 1, 0)
                        }
                    },
                    onSuggestionsEscape: {
                        browserState.dismissSuggestionsPanel()
                    }
                )
                .frame(maxWidth: 520)
                .zIndex(100)
                .onChange(of: searchText) { _, _ in
                    if isAddressBarFocused { browserState.scheduleSuggestionsRefresh() }
                }

                Spacer(minLength: 16)

                RightToolbarControls(
                    activeWebView: activeWebView,
                    showingWebContent: showingWebContent,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    bookmarks: $bookmarks,
                    webPageTitle: $webPageTitle,
                    showingBookmarks: $showingBookmarks,
                    showingFullHistory: $showingFullHistory,
                    showingDownloads: $showingDownloads,
                    showingKeyboardShortcuts: $showingKeyboardShortcuts,
                    onToggleReaderMode: onToggleReaderMode,
                    onShowFind: onShowFind,
                    onOpenLocalAIChat: onOpenLocalAIChat,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onBookmarkCurrentPage: onBookmarkCurrentPage,
                    onGoBack: onGoBack,
                    onGoForward: onGoForward
                )
            }
            .padding(.horizontal, 6)
            .frame(height: AdaptiveChrome.slimToolbarRowHeight)
        } else {
            HStack {
                SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)
                SearxlyTorPill(
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onionHost: browserState.selectedTab?.privacyMode == .onion
                        ? browserState.selectedTab?.currentURL?.host : nil
                )
                Spacer()
                RightToolbarControls(
                    activeWebView: activeWebView,
                    showingWebContent: showingWebContent,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    bookmarks: $bookmarks,
                    webPageTitle: $webPageTitle,
                    showingBookmarks: $showingBookmarks,
                    showingFullHistory: $showingFullHistory,
                    showingDownloads: $showingDownloads,
                    showingKeyboardShortcuts: $showingKeyboardShortcuts,
                    onToggleReaderMode: onToggleReaderMode,
                    onShowFind: onShowFind,
                    onOpenLocalAIChat: onOpenLocalAIChat,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onBookmarkCurrentPage: onBookmarkCurrentPage,
                    onGoBack: onGoBack,
                    onGoForward: onGoForward
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        }
        .background {
            if !isPureHomeState {
                Rectangle()
                    .fill(AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled))
            }
        }
    }
}