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
    let onShowFind: () -> Void
    let onBookmarkCurrentPage: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let currentWebDomain: String?

    let hasPasswordFieldOnPage: Bool
    let isLikelySignupForm: Bool
    let onGeneratePasswordForPage: (() -> Void)?
    let onSaveLoginFromPage: (() -> Void)?
    let onFillLogin: ((String, String, String) -> Void)?
    var onFillTOTP: ((String) -> Void)? = nil

    /// True when the Maximum pill already covers Tor, so the standalone Tor pill is folded into it
    /// (hidden). Reads @Observable PrivacyManager, so this re-evaluates when the mode or backing
    /// network changes.
    ///
    /// Two ways that happens:
    ///   • Maximum Privacy over Tor (either edition) — all traffic is Tor and the Maximum pill owns that
    ///     status, so a Tor pill beside it is pure duplication.
    ///   • Searxly Maximum, whichever lane is picked — the Maximum pill IS this edition's single
    ///     protection indicator (it names the live network and its state). On the VPN lane a standalone
    ///     Tor pill isn't duplication, it's worse: Tor isn't carrying anything, so it sits there greyed
    ///     out next to a header that shows no VPN pill at all (that one is base-app-only), which reads
    ///     as "Maximum turned itself off".
    private var foldTorIntoMaximumPill: Bool {
        guard PrivacyManager.shared.appPrivacyMode == .maximum else { return false }
        return Edition.isMaximum || PrivacyManager.shared.maxProtection == .tor
    }

    var body: some View {
        Group {
        if !isPureHomeState {
            HStack(spacing: 8) {
                if !Edition.isMaximum { SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial) }

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

                // Extension action buttons — clickable logo bubbles that open each extension's popup
                // (or a manage card). Standard tabs only; hidden when none apply. Left of the address bar.
                HeaderExtensionBubbles(
                    webView: browserState.selectedTab?.privacyMode == .standard ? activeWebView : nil,
                    currentURL: browserState.selectedTab?.privacyMode == .standard
                        ? browserState.selectedTab?.currentURL : nil
                )

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

                // Headless coordinator for the Chrome Web Store install flow. The visible "Add to
                // Searxly" button lives inside the store page (an injected popup); this presents the
                // native permission prompt and reflects progress back into that popup.
                ExtensionInstallHost(
                    activeWebView: activeWebView,
                    currentURL: browserState.selectedTab?.currentURL,
                    isStandardTab: browserState.selectedTab?.privacyMode == .standard
                )

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
                    onShowFind: onShowFind,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onFillTOTP: onFillTOTP,
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
                if !Edition.isMaximum { SearxlyVPNPill(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial) }
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
                    onShowFind: onShowFind,
                    currentWebDomain: currentWebDomain,
                    hasPasswordFieldOnPage: hasPasswordFieldOnPage,
                    isLikelySignupForm: isLikelySignupForm,
                    onGeneratePasswordForPage: onGeneratePasswordForPage,
                    onSaveLoginFromPage: onSaveLoginFromPage,
                    onFillLogin: onFillLogin,
                    onFillTOTP: onFillTOTP,
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