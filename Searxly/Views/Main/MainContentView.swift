//
//  MainContentView.swift
//  Searxly
//
//  (Legacy / unwired extraction of main content. Updated comments during monster refactor.
//  Active code now in ContentView + BrowserState; MainContentView kept for reference/compile.)
//

import SwiftUI
import WebKit

struct MainContentView: View {
    @Environment(\.colorScheme) private var colorScheme

    // Web content state
    let showingWebContent: Bool
    let isWebLoading: Bool
    let webProgress: Double
    let activeWebView: WKWebView
    @Binding var webPageTitle: String
    @Binding var webCurrentURL: URL?
    let onWebURLChange: () -> Void
    let onShowingWebContentChange: (Bool) -> Void

    // Navigation state (for back/forward buttons)
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    // Search state
    let isLoadingSearch: Bool
    let searchResults: [SearXNGResult]
    let searchErrorMessage: String?
    let currentSearchCategory: String?
    let lastSearchQuery: String
    let glassEnabled: Bool

    // Search actions
    let onClearSearchResults: () -> Void
    let selectSearchCategory: (String?) -> Void
    let loadInWebView: (URL) -> Void

    // Other
    @Binding var showingSettings: Bool
    @Binding var selectedImageForPreview: SearXNGResult?

    // Find (passed from ContentView for now)
    let onPerformFind: (String) -> Void
    let onExitFind: () -> Void

    @Binding var showingFindBar: Bool
    @Binding var findSearchTerm: String

    var body: some View {
        Group {
            if showingWebContent {
                // The actual browser content
                VStack(spacing: 0) {
                    if isWebLoading || webProgress > 0 && webProgress < 1.0 {
                        ProgressView(value: webProgress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .frame(height: 2)
                    }

                    WebView(
                        webView: activeWebView,
                        isLoading: .constant(isWebLoading),
                        estimatedProgress: .constant(webProgress),
                        pageTitle: $webPageTitle,
                        currentURL: $webCurrentURL,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward
                    )
                    .onChange(of: webCurrentURL) { _, _ in
                        onWebURLChange()
                    }
                    .onChange(of: showingWebContent) { _, newValue in
                        onShowingWebContentChange(newValue)
                    }

                    // Find in Page bar (extracted component)
                    if showingFindBar {
                        FindInPageBar(
                            searchTerm: $findSearchTerm,
                            onFind: onPerformFind,
                            onDismiss: {
                                onExitFind()
                                findSearchTerm = ""
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)

            } else if isLoadingSearch {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Searching SearXNG…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if !searchResults.isEmpty {
                // Search results UI (simplified version of the original for extraction)
                VStack(alignment: .leading, spacing: 12) {
                    // Header with count and clear
                    HStack {
                        let headerTitle: String = {
                            switch currentSearchCategory {
                            case "images": return "Images"
                            case "videos": return "Videos"
                            case "news": return "News"
                            case "general": return "Web"
                            default: return "Results"
                            }
                        }()
                        Text(headerTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("· \(searchResults.count)")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            onClearSearchResults()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .labelStyle(.titleOnly)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)

                    // Category filters
                    if !lastSearchQuery.isEmpty || !searchResults.isEmpty {
                        let categories: [(String, String?)] = [
                            ("All", nil),
                            ("Web", "general"),
                            ("Images", "images"),
                            ("Videos", "videos"),
                            ("News", "news")
                        ]

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(categories, id: \.0) { (label, value) in
                                    let isSelected = currentSearchCategory == value || (currentSearchCategory == nil && value == nil)

                                    Button {
                                        selectSearchCategory(value)
                                    } label: {
                                        Text(label)
                                            .font(.caption2.weight(isSelected ? .semibold : .medium))
                                            .foregroundStyle(isSelected ? .primary : .secondary)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 5)
                                            .background(
                                                isSelected
                                                    ? (glassEnabled ? .thinMaterial : .regularMaterial)
                                                    : .ultraThinMaterial,
                                                in: Capsule()
                                            )
                                            .searxlyGlass(
                                                glassEnabled && isSelected ?
                                                    .interactive : .clear,
                                                in: Capsule()
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(
                                                        isSelected
                                                            ? AdaptiveChrome.border(colorScheme, dark: 0.15)
                                                            : AdaptiveChrome.border(colorScheme, dark: 0.06),
                                                        lineWidth: isSelected ? 0.8 : 0.5
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .scaleEffect(1.0)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .padding(.bottom, 4)
                    }

                    // Results rendering
                    // Use the reworked (Google-like + polished) result rows and media grid.
                    // Grokipedia card omitted in this legacy/unwired path for minimal diff; the primary
                    // ContentView path has the full experience.
                    // Legacy/unwired path (MainContentView). Updated for redesign: use the new modular components
                    // or empty (this file is marked as legacy reference in its own header).
                    // Real SERP now lives in ContentView + Views/SearchResults/.
                    if currentSearchCategory == "images" || currentSearchCategory == "videos" {
                        // Minimal stub rendering to keep legacy compile path alive.
                        Text("Images/Videos (legacy path — see SearchResultsView)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Search results (legacy path — see SearchResultsView)")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)

            } else if let errorMsg = searchErrorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("SearXNG Search Unavailable")
                        .font(.title2.weight(.semibold))

                    Text(errorMsg)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Add My Own SearXNG Instance", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                // Home / new-tab state.
                // The signature premium moment ("S E A R X L Y" SPACEX-style logo + tagline)
                // lives above the AddressBar in TopBarArea. This area is intentionally minimal
                // so the brand treatment + glassy search pill read as the clear hero.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
