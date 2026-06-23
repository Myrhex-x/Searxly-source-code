//
//  TopBarArea.swift
//  Searxly
//
//  Extracted the top toolbar (privacy badges + right controls), AddressBar, and both tab bar layouts.
//  This is the final major extraction needed to make the project build cleanly.
//

import SwiftUI
import WebKit

struct TopBarArea: View {
    // Bindings and state from ContentView
    @Binding var searchText: String
    @FocusState private var localAddressBarFocus: Bool
    let showingWebContent: Bool
    let glassEnabled: Bool
    let isHomeState: Bool
    let toolbarMaterial: Material
    let history: [HistoryItem]
    @Binding var bookmarks: [BookmarkItem]
    let onAddressBarSubmit: () -> Void

    @Binding var tabs: [BrowserTab]
    @Binding var selectedTabID: UUID?
    @Binding var showingWebContentForTabs: Bool
    @Binding var hoveredTabID: UUID?

    let tabLayout: TabLayout
    let newTabAction: () -> Void
    let newPrivateTabAction: () -> Void
    let closeTabAction: (BrowserTab) -> Void

    // For RightToolbarControls
    let activeWebView: WKWebView
    let canGoBack: Bool
    let canGoForward: Bool
    @Binding var webPageTitle: String
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingSettings: Bool
    @Binding var showingKeyboardShortcuts: Bool

    // Left side instance display
    let currentInstanceDisplay: String

    // Feature actions (Reader Mode, Find in Page)
    var onToggleReaderMode: (() -> Void)? = nil
    var onShowFind: (() -> Void)? = nil
    var onOpenLocalAIChat: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                // Left privacy badges (kept simple here for extraction)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.fill")
                            .foregroundStyle(.green)
                        Text("SearXNG")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .glassEffect(glassEnabled ? .regular.interactive() : .clear, in: Capsule())

                    // Rank 2: Live local SearXNG status (next to privacy badge)
                    let searxngManager = LocalSearxngManager.shared
                    HStack(spacing: 4) {
                        Circle()
                            .fill(searxngStatusColor(searxngManager.status))
                            .frame(width: 8, height: 8)
                        Text(searxngStatusShort(searxngManager.status))
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .onTapGesture {
                        // Quick action: open Settings to full local SearXNG controls
                        showingSettings = true
                    }

                    // Rank 1 polish: show when the current tab is a private/ephemeral session
                    if let selectedID = selectedTabID,
                       let selectedTab = tabs.first(where: { $0.id == selectedID }),
                       selectedTab.isPrivate {
                        Text("PRIVATE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                    }

                    Button {
                        showingSettings = true
                    } label: {
                        Text(currentInstanceDisplay)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .glassEffect(glassEnabled ? .regular.interactive() : .clear, in: Capsule())
                    .help("Current SearXNG instance. Click to change in Settings.")
                }

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
                    onOpenLocalAIChat: onOpenLocalAIChat
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Removed dedicated background so the badges blend with the same grey as the central address bar area
            // .background(toolbarMaterial)

            // Premium brand mark — SPACEX-inspired "S E A R X L Y" only on clean home state.
            // Sits centered directly above the AddressBar (respects the 48pt horizontal sacred line).
            if isHomeState {
                VStack(spacing: 4) {
                    SearxlyLogo(glassEnabled: glassEnabled)
                    Text("Private search. Yours.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .tracking(0.5)
                }
                .padding(.top, 48)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            // Address Bar
            // On home (with the logo above): reduced width + extra round + perfectly centered.
            // On all other states: full comfortable width using the sacred 48pt side padding.
            if isHomeState {
                // Hero (centered, generous).
                AddressBar(
                    text: $searchText,
                    isFocused: $localAddressBarFocus,
                    showingWebContent: showingWebContent,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onSubmit: onAddressBarSubmit,
                    isHero: true
                )
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 16)
                .zIndex(100)
                // Suggestions removed from home page search bar.
            } else {
                // Non-home header bar (web or SERP) — 48pt sacred padding.
                AddressBar(
                    text: $searchText,
                    isFocused: $localAddressBarFocus,
                    showingWebContent: showingWebContent,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onSubmit: onAddressBarSubmit,
                    isHero: false
                )
                .padding(.horizontal, 48)
                .padding(.top, 16)
                .zIndex(100)
                // Suggestions / search history removed from header too (results or webpage open).
            }

            // Horizontal Tab Bar (only in horizontal layout mode)
            if tabLayout == .horizontal, tabs.count > 0 {
                HorizontalTabBar(
                    tabs: $tabs,
                    selectedTabID: $selectedTabID,
                    searchText: $searchText,
                    showingWebContent: $showingWebContentForTabs,
                    hoveredTabID: $hoveredTabID,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    newTabAction: newTabAction,
                    newPrivateTabAction: newPrivateTabAction,
                    closeTabAction: closeTabAction
                )
            }
        }
    }
}

// MARK: - Local SearXNG status helpers
private func searxngStatusColor(_ status: SearxngStatus) -> Color {
    switch status {
    case .running: return .green
    case .stopped: return .gray
    case .starting, .stopping: return .orange
    case .error: return .red
    }
}

private func searxngStatusShort(_ status: SearxngStatus) -> String {
    switch status {
    case .running: return "Local"
    case .stopped: return "Off"
    case .starting: return "Starting"
    case .stopping: return "Stopping"
    case .error: return "Error"
    }
}
