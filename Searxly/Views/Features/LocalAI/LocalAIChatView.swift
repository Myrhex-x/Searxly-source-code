//
//  LocalAIChatView.swift
//  Searxly
//
//  Extracted the fully wired Local AI Chat view from ContentView.
//  This is the content provider that wires the tool closures (performPrivateSearch, openWebsite, retrieveRAG)
//  into LocalAIChatSheet.
//
//  The presentation (draggable floating panel) has already been extracted to LocalAIChatFloatingPanel.
//  This extraction moves the "chat content wiring" (the closures that talk to SearXNGService and
//  LocalIntelligenceManager) into the Features/LocalAI/ area where the chat UI belongs.
//
//  ContentView now just references this view for the overlay/sheet content.

import SwiftUI
import os

struct LocalAIChatView: View {
    // BrowserState is @Observable (class). Use @Bindable so we can derive bindings to its
    // properties (e.g. $browserState.showingLocalAIChat for the sheet's isPresented).
    @Bindable var browserState: BrowserState

    var body: some View {
        LocalAIChatSheet(
            isPresented: $browserState.showingLocalAIChat,
            performPrivateSearch: { query in
                // Only ever uses the user's currently configured private/local instances.
                do {
                    let (r, _) = try await SearXNGService.shared.searchWithFallback(
                        query: query,
                        instances: browserState.searxInstances,
                        language: Localization.searchLanguageCode
                    )
                    return r
                } catch {
                    Log.app.error("Private search tool failed: \(error)")
                    return []
                }
            },
            // The two (and only two) work tools after the 2026-06 minimal-tool rework.
            // All previous agentic tools (history search, open tabs, bookmark, new private search tab) removed.
            openWebsite: { description in
                // Force clear any lingering search results and switch to web mode immediately.
                // Prevents getting stuck in SERP UI while async resolution + tab creation happens.
                browserState.clearNativeSearch()
                browserState.showingWebContent = true
                browserState.openWebsite(description: description)
            },
            // Citation source chips open the exact source URL in a new tab.
            openURLInTab: { url in
                browserState.clearNativeSearch()
                browserState.showingWebContent = true
                browserState.openResultsInTabs(urls: [url])
            },
            // MARK: Extended cloud-agent tools (Searxly AI 70B). All read from live BrowserState / services.
            searchHistory: { query in
                let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return [] }
                return browserState.history
                    .filter { $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle) }
                    .sorted { $0.date > $1.date }
                    .prefix(8)
                    .map { $0 }
            },
            searchBookmarks: { query in
                let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !needle.isEmpty else { return [] }
                return browserState.bookmarks
                    .filter {
                        $0.title.lowercased().contains(needle)
                            || $0.url.lowercased().contains(needle)
                            || ($0.note ?? "").lowercased().contains(needle)
                    }
                    .sorted { $0.dateAdded > $1.dateAdded }
                    .prefix(8)
                    .map { $0 }
            },
            searchByCategory: { query, category in
                do {
                    let (r, _) = try await SearXNGService.shared.searchWithFallback(
                        query: query,
                        categories: category,
                        instances: browserState.searxInstances,
                        language: Localization.searchLanguageCode
                    )
                    return r
                } catch {
                    Log.app.error("Category search tool failed: \(error)")
                    return []
                }
            },
            openURLsInTabs: { urls in
                browserState.clearNativeSearch()
                browserState.showingWebContent = true
                browserState.openResultsInTabs(urls: urls)
            },
            lookupEntity: { entity in
                await KnowledgePanelService.resolve(
                    query: entity,
                    imageInstanceURL: browserState.currentSearxInstance.url
                )
            },
            privacyStatusProvider: {
                AIPrivacyStatusSnapshot(
                    torEnabled: TorManager.shared.isEnabled,
                    torRunning: TorManager.shared.isRunning,
                    vpnConnected: SystemVPNManager.shared.isConnected,
                    vpnHasActivePass: ManagedVPNService.shared.hasActivePass,
                    currentPageHost: browserState.webCurrentURL?.host,
                    onionOfferHost: browserState.activeOnionLocationOffer?.pageHost,
                    onionOfferURL: browserState.activeOnionLocationOffer?.onionURL.absoluteString,
                    searxInstanceName: browserState.currentSearxInstance.name,
                    searxIsPrivate: !SearXNGInstance.isPublicInstance(url: browserState.currentSearxInstance.url)
                )
            },
            lastSearchQuery: browserState.lastSearchQuery,
            // RAG — live data from BrowserState
            retrieveRAG: { query in
                await LocalIntelligenceManager.shared.retrieveRAGIfEnabled(query: query)
            },
            // "Ask Searxly AI" selection seed from the page right-click menu.
            seed: $browserState.pendingAIChatSeed
        )
    }
}