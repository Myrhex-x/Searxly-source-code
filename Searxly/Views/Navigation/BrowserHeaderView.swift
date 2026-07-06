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

    /// Wallet is an opt-in surface — when disabled, the ☰ menu simply has no wallet row
    /// (the menu hides any row whose action closure is nil).
    @AppStorage(WalletConfig.Keys.surfaceEnabled) private var walletSurfaceEnabled = WalletConfig.surfaceEnabledDefault

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
    let onSummarizePage: () -> Void
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

    /// True when the app is in Maximum Privacy AND routing through Tor: the Maximum pill fully covers
    /// the Tor connection, so the standalone Tor pill is folded into it (hidden). Reads @Observable
    /// PrivacyManager, so this re-evaluates when the mode or backing network changes.
    private var foldTorIntoMaximumPill: Bool {
        PrivacyManager.shared.appPrivacyMode == .maximum && PrivacyManager.shared.maxProtection == .tor
    }

    var body: some View {
        Group {
        if !isPureHomeState {
            HStack(spacing: 8) {
                SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)

                // In Maximum + Tor, ALL traffic is Tor and the Maximum pill already owns that status
                // (network + live circuit + new-circuit) — so the standalone Tor pill would just
                // duplicate it. Fold it in: hide the Tor pill here (still shown in any other mode,
                // where it's the .onion control).
                if !foldTorIntoMaximumPill {
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
                }

                SearxlyPrivacyPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)

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
                    siteHost: currentWebDomain ?? "",
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
                    onSummarizePage: AIFeatures.programEnabled ? onSummarizePage : nil,
                    onShowFind: onShowFind,
                    onOpenLocalAIChat: AIFeatures.programEnabled ? onOpenLocalAIChat : nil,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onBookmarkCurrentPage: onBookmarkCurrentPage,
                    onGoBack: onGoBack,
                    onGoForward: onGoForward,
                    onOpenExtensions: ExtensionFeatures.programEnabled
                        ? { NotificationCenter.default.post(name: .showExtensionsTabRequested, object: nil) } : nil,
                    onOpenWallet: walletSurfaceEnabled ? { browserState.showingWallet = true } : nil,
                    onOpenSettings: { browserState.showingSettings = true },
                    onClearBrowsingData: { browserState.showingClearData = true },
                    onImportData: { browserState.showingImportData = true }
                )
            }
            .padding(.horizontal, 6)
            .frame(height: AdaptiveChrome.slimToolbarRowHeight)
        } else {
            HStack {
                SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)
                if !foldTorIntoMaximumPill {
                    SearxlyTorPill(
                        glassEnabled: glassEnabled,
                        toolbarMaterial: toolbarMaterial,
                        onionHost: browserState.selectedTab?.privacyMode == .onion
                            ? browserState.selectedTab?.currentURL?.host : nil
                    )
                }
                SearxlyPrivacyPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)
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
                    onSummarizePage: AIFeatures.programEnabled ? onSummarizePage : nil,
                    onShowFind: onShowFind,
                    onOpenLocalAIChat: AIFeatures.programEnabled ? onOpenLocalAIChat : nil,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onBookmarkCurrentPage: onBookmarkCurrentPage,
                    onGoBack: onGoBack,
                    onGoForward: onGoForward,
                    onOpenExtensions: ExtensionFeatures.programEnabled
                        ? { NotificationCenter.default.post(name: .showExtensionsTabRequested, object: nil) } : nil,
                    onOpenWallet: walletSurfaceEnabled ? { browserState.showingWallet = true } : nil,
                    onOpenSettings: { browserState.showingSettings = true },
                    onClearBrowsingData: { browserState.showingClearData = true },
                    onImportData: { browserState.showingImportData = true }
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