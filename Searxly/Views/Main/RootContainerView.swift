//
//  RootContainerView.swift
//  Searxly
//
//  Legacy / deprecated wrapper. Not wired into the active UI hierarchy
//  (see DESIGN-PREMIUM.md and ContentView.swift — now thin post-refactor to BrowserState).
//  Kept only for reference. Do not add new parameters or logic here.
//

import SwiftUI
import WebKit

struct RootContainerView: View {
    // All the state passed down from ContentView
    // (abbreviated for brevity in this extraction step - full list mirrors the previous calls)

    @Binding var searchText: String
    @FocusState var isAddressBarFocused: Bool
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

    let activeWebView: WKWebView
    let canGoBack: Bool
    let canGoForward: Bool
    @Binding var webPageTitle: String
    @Binding var showingBookmarks: Bool
    @Binding var showingFullHistory: Bool
    @Binding var showingDownloads: Bool
    @Binding var showingSettings: Bool
    @Binding var showingKeyboardShortcuts: Bool

    let currentInstanceDisplay: String

    // Main content params
    let isWebLoading: Bool
    let webProgress: Double
    let webCurrentURL: Binding<URL?>
    let onWebURLChange: () -> Void
    let onShowingWebContentChange: (Bool) -> Void
    let isLoadingSearch: Bool
    let searchResults: [SearXNGResult]
    let searchErrorMessage: String?
    let currentSearchCategory: String?
    let lastSearchQuery: String
    let onClearSearchResults: () -> Void
    let selectSearchCategory: (String?) -> Void
    let loadInWebView: (URL) -> Void
    @Binding var selectedImageForPreview: SearXNGResult?

    var body: some View {
        VStack(spacing: 0) {
            TopBarArea(
                searchText: $searchText,
                showingWebContent: showingWebContent,
                glassEnabled: glassEnabled,
                isHomeState: isHomeState,
                toolbarMaterial: toolbarMaterial,
                history: history,
                bookmarks: $bookmarks,
                onAddressBarSubmit: onAddressBarSubmit,
                tabs: $tabs,
                selectedTabID: $selectedTabID,
                showingWebContentForTabs: $showingWebContentForTabs,
                hoveredTabID: $hoveredTabID,
                tabLayout: tabLayout,
                newTabAction: newTabAction,
                newPrivateTabAction: newPrivateTabAction,
                closeTabAction: closeTabAction,
                activeWebView: activeWebView,
                canGoBack: false,
                canGoForward: false,
                webPageTitle: $webPageTitle,
                showingBookmarks: $showingBookmarks,
                showingFullHistory: $showingFullHistory,
                showingDownloads: $showingDownloads,
                showingSettings: $showingSettings,
                showingKeyboardShortcuts: $showingKeyboardShortcuts,
                currentInstanceDisplay: currentInstanceDisplay
            )

            MainContentView(
                showingWebContent: showingWebContent,
                isWebLoading: isWebLoading,
                webProgress: webProgress,
                activeWebView: activeWebView,
                webPageTitle: $webPageTitle,
                webCurrentURL: webCurrentURL,
                onWebURLChange: onWebURLChange,
                onShowingWebContentChange: onShowingWebContentChange,
                canGoBack: Binding.constant(false),
                canGoForward: Binding.constant(false),
                isLoadingSearch: isLoadingSearch,
                searchResults: searchResults,
                searchErrorMessage: searchErrorMessage,
                currentSearchCategory: currentSearchCategory,
                lastSearchQuery: lastSearchQuery,
                glassEnabled: glassEnabled,
                onClearSearchResults: onClearSearchResults,
                selectSearchCategory: selectSearchCategory,
                loadInWebView: loadInWebView,
                showingSettings: Binding.constant(false),
                selectedImageForPreview: $selectedImageForPreview,
                onPerformFind: { _ in },
                onExitFind: {},
                showingFindBar: .constant(false),
                findSearchTerm: .constant("")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 40)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(.regularMaterial)
    }
}
