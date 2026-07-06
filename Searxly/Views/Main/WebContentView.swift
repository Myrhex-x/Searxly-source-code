//
//  WebContentView.swift
//  Searxly
//
//  Extracted the web content presentation (progress bar, find-in-page, WebView + its lifecycle observers)
//  from the large mainContentArea in ContentView. This keeps the browser page rendering and its
//  side effects (history repair, login detection, stabilization) in one focused file.

import SwiftUI
import WebKit

struct WebContentView: View {
    // Web state (passed from parent orchestration)
    let isWebLoading: Bool
    let webProgress: Double
    let activeWebView: WKWebView
    @Binding var webPageTitle: String
    @Binding var webCurrentURL: URL?
    @Binding var webViewCanGoBack: Bool
    @Binding var webViewCanGoForward: Bool

    // Find bar
    @Binding var showingFindBar: Bool
    @Binding var findSearchTerm: String
    let onPerformFind: (String) -> Void
    let onExitFind: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isWebLoading || webProgress > 0 && webProgress < 1.0 {
                ProgressView(value: webProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            }

            // Find in page bar (attached to web content, below progress)
            if showingFindBar {
                FindInPageBar(
                    searchTerm: $findSearchTerm,
                    onFind: onPerformFind,
                    onDismiss: {
                        onExitFind()
                        findSearchTerm = ""
                    }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            WebView(
                webView: activeWebView,
                isLoading: .constant(isWebLoading),
                estimatedProgress: .constant(webProgress),
                pageTitle: $webPageTitle,
                currentURL: $webCurrentURL,
                canGoBack: $webViewCanGoBack,
                canGoForward: $webViewCanGoForward
            )
            .id(activeWebView)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        // (The "where this link goes" strip is drawn as an AppKit subview inside WebViewContainer so
        // it sits above the heavyweight WKWebView — a SwiftUI overlay here would render behind it.)
        // Clip to the true content pane bounds. Prevents any transient overflow visuals
        // during first paint or while the container is settling size after a tab switch / wake.
        .clipped()
    }
}