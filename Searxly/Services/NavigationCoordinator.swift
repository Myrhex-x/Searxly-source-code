//
//  NavigationCoordinator.swift
//  Searxly
//
//  WebKit navigation, per-tab history stack, and toolbar browser actions.
//

import Foundation
import SwiftUI
import WebKit
import os

extension BrowserState {
    func loadInWebView(_ url: URL) {
        loadInWebView(url, recordInHistory: true)
    }

    func loadInWebView(_ url: URL, recordInHistory: Bool) {
        // .onion services are only reachable over Tor. Any stray .onion load (address bar, history,
        // bookmarks, restored session, programmatic) is handed off to a dedicated Tor-routed onion
        // tab — unless we're already in one, in which case it navigates in place below.
        if url.isOnionService, selectedTab?.privacyMode != .onion {
            openOnionURL(url)
            return
        }

        // Navigating an onion (Tor) tab to a clearnet site must NOT keep it classified as a Tor tab
        // (its privacyMode is immutable and the sidebar groups by it). Open clearnet in a fresh standard
        // tab beside the onion one instead of loading it inside the Tor tab.
        if !url.isOnionService, selectedTab?.privacyMode == .onion {
            let standardTab = BrowserTab(kind: .web)   // .standard privacy by default
            if let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                tabs.insert(standardTab, at: idx + 1)
            } else {
                tabs.append(standardTab)
            }
            selectedTabID = standardTab.id
            // Recurse: selectedTab is now standard, so this falls through to the normal load path.
            loadInWebView(url, recordInHistory: recordInHistory)
            return
        }

        if recordInHistory {
            pushCurrentBrowseStateToBackStack()
        }

        showingWebContent = true

        if let tab = selectedTab {
            tab.currentURL = url
            tab.title = url.host ?? "Loading..."
        }

        // History with dedup — only when the user has history recording enabled.
        // CRITICAL FIX (suggestion pollution): *always* use a strict host-derived title at record time.
        // Never read selectedTab.title (stale from previous page in the tab) or any other source.
        // The previous "safe" read of tab.title was still racy and the documented source of
        // "Youtube - speedtest.com" (and "Speedtest, x.com") rows in the address bar suggestions.
        // We record host-only immediately; later live title from the webview (via snapshot updater
        // or refine) will correct it. This + stricter SuggestionProvider filters + defensive
        // fromHistory title fallback = the "huge fix" for the address bar suggestion system.
        if PrivacyManager.shouldRecordHistory() {
            let urlStr = url.absoluteString
            let hostOnly = url.host ?? urlStr
            let safeTitle = hostOnly // deliberately ignore any in-flight tab.title or global pageTitle
            history.removeAll { $0.url == urlStr }
            let item = HistoryItem(url: urlStr, title: safeTitle)
            history.append(item)
            if history.count > 150 {
                history.removeFirst(history.count - 150)
            }
            Persistence.saveHistory(history)
        }

        // The KVO in WebViewRepresentable will update the published web* states (isWebLoading etc.)

        // Persist the session promptly when a URL is loaded into a tab. This ensures that
        // pages the user actually visits are remembered even if the app is quit without a
        // clean willTerminate (very common on macOS).
        saveCurrentSession()

        // Small delay before actually starting the network load.
        // When coming from the home / address bar state, setting showingWebContent=true
        // causes SwiftUI to insert the WebViewRepresentable + WebViewContainer into the tree.
        // Giving the layout system one tick means the container usually has its real pane size
        // (content area width) by the time the HTML arrives and the page's scripts do their
        // first measurement + centering of things like the speedtest "GO" button.
        // Without this, the page can initialize against a 0 or interim size and place UI at left:0.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.activeWebView.load(URLRequest(url: url))

            // Early stabilization poke (the big work is done by didCommit/didFinish + Container).
            self.activeWebView.evaluateJavaScript("""
            (function(){ try { window.dispatchEvent(new Event('resize')); void document.documentElement.offsetWidth; } catch(e){} })();
            """, completionHandler: nil)
        }
    }

    func openSearchResultInNewTab(_ result: SearXNGResult) {
        guard let targetURL = URL(string: result.url) else { return }

        // .onion results are only reachable over Tor — open them in a Tor-routed onion tab.
        if targetURL.isOnionService {
            openOnionURL(targetURL)
            return
        }

        let newTab = BrowserTab(kind: .web)   // standard (see policy comment above)
        newTab.currentURL = targetURL
        // Use host initially for tab title too (result.title can be the indexed SERP title and was
        // a vector for the crossed history suggestion bug). Live title will correct it on load.
        newTab.title = targetURL.host ?? "Loading..."

        tabs.append(newTab)
        selectedTabID = newTab.id
        showingWebContent = true
        searchText = targetURL.absoluteString

        // History (dedup + cap) — only when recording is enabled, mirrors loadInWebView behavior.
        // FIX: ignore the search-result title we put on the tab (it can be the SERP hit title, not the
        // live page title, and contributed to crossed "Youtube - speedtest" style history rows).
        // Force strict host-derived placeholder; the live title will arrive via the snapshot path.
        if PrivacyManager.shouldRecordHistory() {
            let urlStr = targetURL.absoluteString
            let hostOnly = targetURL.host ?? urlStr
            history.removeAll { $0.url == urlStr }
            let item = HistoryItem(url: urlStr, title: hostOnly)
            history.append(item)
            if history.count > 150 { history.removeFirst(history.count - 150) }
            Persistence.saveHistory(history)
        }

        saveCurrentSession()

        // Same delayed + stabilization pattern as loadInWebView so first paint is reliable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.activeWebView.load(URLRequest(url: targetURL))
            self.activeWebView.evaluateJavaScript("""
            (function(){ try { window.dispatchEvent(new Event('resize')); void document.documentElement.offsetWidth; } catch(e){} })();
            """, completionHandler: nil)
        }
    }
    // Sync called from WebView onChange
    func syncAddressBarWithWebURL() {
        if showingWebContent, let url = webCurrentURL {
            searchText = url.absoluteString
        }
        syncSelectedTabMetadataFromWeb()
    }

    /// Keeps the selected tab's stored URL/title in sync with live WebKit state (sidebar favicons + labels).
    func syncSelectedTabMetadataFromWeb() {
        guard let tab = selectedTab, tab.kind == .web else { return }
        if let url = webCurrentURL ?? tab.webView?.url {
            tab.currentURL = url
        }
        let trimmedTitle = webPageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            tab.title = trimmedTitle
        }
    }

    /// When switching tabs, mirror the selected tab into the global web bindings.
    func syncWebStateFromSelectedTab() {
        guard let tab = selectedTab else { return }
        guard tab.kind == .web else {
            showingWebContent = false
            return
        }
        let url = tab.currentURL ?? tab.webView?.url
        webCurrentURL = url
        if !tab.title.isEmpty {
            webPageTitle = tab.title
        }
        if let url {
            showingWebContent = true
            if searchText.isEmpty || searchText == webPageTitle {
                searchText = url.absoluteString
            }
        } else {
            showingWebContent = false
        }
    }

    // Convenience for external notif handlers (ContentView forwards)
    func handleShowKeyboardShortcuts() {
        showingKeyboardShortcuts = true
    }

    func handleDataRestored() {
        // A backup restore / recovery may have rewritten AppData.json out from under the in-memory
        // cache. Drop it so we re-read the authoritative on-disk state instead of stale cached data.
        Persistence.invalidateCache()
        // Re-load everything the backup may have changed
        loadPersistedData()
    }

    // Called on panic notif (ContentView still shows the serious confirmation sheet)
    func panicWipeRequested() {
        // Actual wipe is driven by PrivacyManager + callers in the confirmation flow.
        // State just clears its local caches so UI reflects immediately after.
        searchResults = []
        searchText = ""
        history = []
        bookmarks = []
        suggestions = []
        suggestionsSelectedIndex = 0
        highlightedResultURL = nil
        // tabs reset etc. handled by the panic flow in ContentView / Privacy
    }
    // MARK: - History title repair (fixes stale titles like "Youtube" recorded for speedtest.net)

    /// Preferred entry point: the coordinator / observers pass an explicit (url, title) snapshot
    /// taken atomically from the WKWebView at the observation moment. This avoids races between
    /// the global webPageTitle binding and webCurrentURL updates.
    func updateHistoryTitleSnapshot(url: URL?, title: String?) {
        guard let u = url, let raw = title else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refineHistoryTitleInternal(urlStr: u.absoluteString, newTitle: trimmed)
    }

    /// Legacy / binding-driven path (still used by the .onChange in ContentView for now).
    /// We pass the URL we have at the moment the webPageTitle changed.
    func refineHistoryTitle(for url: URL, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refineHistoryTitleInternal(urlStr: url.absoluteString, newTitle: trimmed)
    }

    /// Internal implementation shared by both paths. Only updates if the URL still matches
    /// an existing history entry for *that exact URL* (defensive against late KVO or tab switches).
    private func refineHistoryTitleInternal(urlStr: String, newTitle: String) {
        if let idx = history.firstIndex(where: { $0.url == urlStr }) {
            let oldTitle = history[idx].title
            if oldTitle != newTitle {
                let oldDate = history[idx].date
                history[idx] = HistoryItem(url: urlStr, title: newTitle, date: oldDate)
                Persistence.saveHistory(history)

                // Keep any tab with this URL in sync (sidebar favicons/labels).
                for tab in tabs where tab.kind == .web {
                    let tabURL = tab.currentURL?.absoluteString ?? tab.webView?.url?.absoluteString
                    if tabURL == urlStr {
                        tab.title = newTitle
                    }
                }
            }
        }
    }
    // MARK: - Native + web navigation history

    private func noteNavigationHistoryChanged() {
        navigationHistoryRevision &+= 1
    }

    private func currentBrowseDestination() -> TabBrowseDestination {
        if showingWebContent {
            let url = webCurrentURL?.absoluteString
                ?? activeWebView.url?.absoluteString
                ?? selectedTab?.currentURL?.absoluteString
                ?? ""
            let title = webPageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return .web(url: url, title: title.isEmpty ? (URL(string: url)?.host ?? "") : title)
        }

        if !searchResults.isEmpty || !lastSearchQuery.isEmpty || searchErrorMessage != nil {
            return .search(currentSearchSnapshot())
        }

        return .home
    }

    private func currentSearchSnapshot() -> SearchSnapshot {
        SearchSnapshot(
            searchText: searchText,
            searchResults: searchResults,
            lastSearchQuery: lastSearchQuery,
            lastEffectiveSearchQuery: lastEffectiveSearchQuery,
            currentSearchCategory: currentSearchCategory,
            searchErrorMessage: searchErrorMessage,
            lastSearchInstanceURL: lastSearchInstanceURL,
            searchPageNo: searchPageNo,
            canLoadMoreResults: canLoadMoreResults,
            knowledgePanelState: knowledgePanelState
        )
    }

    func pushCurrentBrowseStateToBackStack() {
        guard let tab = selectedTab, tab.kind == .web else { return }
        tab.navigationHistory.pushBack(currentBrowseDestination())
        noteNavigationHistoryChanged()
    }

    private func applySearchSnapshot(_ snapshot: SearchSnapshot) {
        cancelKnowledgePanelTask()
        searchText = snapshot.searchText
        searchResults = snapshot.searchResults
        lastSearchQuery = snapshot.lastSearchQuery
        lastEffectiveSearchQuery = snapshot.lastEffectiveSearchQuery
        currentSearchCategory = snapshot.currentSearchCategory
        searchErrorMessage = snapshot.searchErrorMessage
        lastSearchInstanceURL = snapshot.lastSearchInstanceURL
        searchPageNo = snapshot.searchPageNo
        canLoadMoreResults = snapshot.canLoadMoreResults
        knowledgePanelState = snapshot.knowledgePanelState
        isLoadingSearch = false
        isLoadingMoreResults = false
        consecutiveEmptyLoadMorePages = 0
        highlightedResultURL = nil

    }

    private func restoreBrowseDestination(_ destination: TabBrowseDestination) {
        dismissSuggestionsPanel()

        switch destination {
        case .home:
            showingWebContent = false
            searchText = ""
            clearNativeSearch()

        case .search(let snapshot):
            applySearchSnapshot(snapshot)
            showingWebContent = false

        case .web(let urlString, let title):
            guard let url = URL(string: urlString), !urlString.isEmpty else { return }
            showingWebContent = true
            searchText = urlString
            webPageTitle = title
            webCurrentURL = url
            clearNativeSearch()

            if let tab = selectedTab {
                tab.currentURL = url
                if !title.isEmpty {
                    tab.title = title
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.activeWebView.load(URLRequest(url: url))
            }
        }
    }

    // MARK: - Header toolbar actions (back/forward/reload/bookmark/reader/find)

    func goBack() {
        guard let tab = selectedTab, tab.kind == .web else { return }

        if showingWebContent, webViewCanGoBack {
            activeWebView.goBack()
            return
        }

        let current = currentBrowseDestination()
        guard let previous = tab.navigationHistory.popBack() else { return }
        tab.navigationHistory.pushForward(current)
        restoreBrowseDestination(previous)
        noteNavigationHistoryChanged()
    }

    func goForward() {
        guard let tab = selectedTab, tab.kind == .web else { return }

        if showingWebContent, webViewCanGoForward {
            activeWebView.goForward()
            return
        }

        let current = currentBrowseDestination()
        guard let next = tab.navigationHistory.popForward() else { return }
        tab.navigationHistory.appendBack(current)
        restoreBrowseDestination(next)
        noteNavigationHistoryChanged()
    }

    func reload() {
        activeWebView.reload()
    }

    func stopLoading() {
        activeWebView.stopLoading()
    }

    // MARK: - Zoom & Print (web page actions)

    /// Discrete page-zoom stops, mirroring Safari's ⌘+/⌘−/⌘0 feel. `WKWebView.pageZoom` scales the
    /// whole page (text + layout); because it lives on the WKWebView, each tab keeps its own zoom.
    private static let zoomStops: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    func zoomIn()  { stepZoom(by: 1) }
    func zoomOut() { stepZoom(by: -1) }

    /// Returns the page to 100%. No-op on non-web tabs (passwords/bookmarks/downloads) and home/search.
    func resetZoom() {
        guard let wv = selectedTab?.webView else { return }
        wv.pageZoom = 1.0
    }

    private func stepZoom(by delta: Int) {
        Log.web.notice("[zoomdiag] stepZoom delta=\(delta) hasWebView=\(self.selectedTab?.webView != nil) showingWeb=\(self.showingWebContent)")
        guard let wv = selectedTab?.webView else { return }
        let stops = Self.zoomStops
        let current = wv.pageZoom
        // Snap to the nearest defined stop, then move one stop in the requested direction.
        let nearest = stops.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 5
        let target = min(max(nearest + delta, 0), stops.count - 1)
        wv.pageZoom = stops[target]
        Log.web.notice("[zoomdiag] pageZoom \(current) -> \(stops[target])")
    }

    /// Prints the current web page (⌘P). No-op on non-web tabs and on home/search (nothing to print).
    func printCurrentPage() {
        guard let wv = selectedTab?.webView, wv.url != nil else { return }
        let operation = wv.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = wv.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func closeCurrentTab() {
        if let selectedID = selectedTabID,
           let tab = tabs.first(where: { $0.id == selectedID }) {
            closeTab(tab)
        } else if !tabs.isEmpty {
            closeTab(tabs[0])
        }
    }

    /// Closes every tab and replaces the set with a single fresh new tab.
    /// Mirrors the "last tab closed" reset behavior in closeTab.
    /// Pauses media on outgoing web tabs before dropping them.
    func closeAllTabs() {
        for tab in tabs where tab.kind == .web {
            tab.pauseAllMediaForClose()
        }
        tabs = [BrowserTab(kind: .web)]
        selectedTabID = tabs[0].id
        showingWebContent = false
        searchText = ""
        clearNativeSearch()
        saveCurrentSession()
    }

    func bookmarkCurrentPage() {
        guard let urlStr = activeWebView.url?.absoluteString else { return }

        if BookmarkURLMatcher.contains(url: urlStr, in: bookmarks) {
            var updated = bookmarks
            BookmarkURLMatcher.remove(url: urlStr, from: &updated)
            bookmarks = updated
            saveAllData()
            return
        }

        // Prefer the live title directly from the WKWebView (most up-to-date).
        // Fall back to the bound webPageTitle or host. Avoids the same stale-title
        // pollution that used to produce "Youtube - speedtest.net" style entries.
        let live = activeWebView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromState = webPageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = activeWebView.url?.host ?? "Untitled"
        let title = !live.isEmpty ? live : (!fromState.isEmpty ? fromState : host)

        var updated = bookmarks
        BookmarkURLMatcher.remove(url: urlStr, from: &updated)
        let item = BookmarkItem(url: urlStr, title: title)
        updated.insert(item, at: 0)
        if updated.count > BookmarkLimits.maxCount {
            updated.removeLast(updated.count - BookmarkLimits.maxCount)
        }
        bookmarks = updated
        saveAllData()

        revealBookmarksBarOnFirstBookmark()
    }

    /// Toggles a bookmark for a specific tab (not necessarily the active one). Used by the sidebar
    /// tab right-click "Bookmark Tab" action. Mirrors bookmarkCurrentPage but sources the URL/title
    /// from the given tab so background tabs can be bookmarked without switching to them.
    func bookmarkTab(_ tab: BrowserTab) {
        guard tab.kind == .web,
              let url = tab.currentURL ?? tab.webView?.url,
              !url.absoluteString.isEmpty else { return }
        let urlStr = url.absoluteString

        if BookmarkURLMatcher.contains(url: urlStr, in: bookmarks) {
            var updated = bookmarks
            BookmarkURLMatcher.remove(url: urlStr, from: &updated)
            bookmarks = updated
            saveAllData()
            return
        }

        // Prefer the live WKWebView title, then the tab's tracked title, then the host.
        let live = tab.webView?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tracked = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url.host ?? "Untitled"
        let title = !live.isEmpty ? live : (!tracked.isEmpty && tracked != "New Tab" ? tracked : host)

        var updated = bookmarks
        BookmarkURLMatcher.remove(url: urlStr, from: &updated)
        updated.insert(BookmarkItem(url: urlStr, title: title), at: 0)
        if updated.count > BookmarkLimits.maxCount {
            updated.removeLast(updated.count - BookmarkLimits.maxCount)
        }
        bookmarks = updated
        saveAllData()

        revealBookmarksBarOnFirstBookmark()
    }

    /// The very first time the user saves a bookmark, reveal the top bookmarks bar so the saved page is
    /// immediately visible (it's off by default). One-time only — if the user later hides the bar, it
    /// stays hidden. The key is shared with the @AppStorage("bookmarksBarVisible") used by the UI.
    private func revealBookmarksBarOnFirstBookmark() {
        let autoShownKey = "bookmarksBarAutoShownOnce"
        guard !UserDefaults.standard.bool(forKey: autoShownKey) else { return }
        UserDefaults.standard.set(true, forKey: autoShownKey)
        UserDefaults.standard.set(true, forKey: "bookmarksBarVisible")
    }

    /// Summarize the current page with Searxly AI — extracts VISIBLE text (the same injection-resistant
    /// extractor the right-click menu uses) and routes it to the quick-answer popup. Replaces the removed
    /// reader mode as the ☰-menu page action.
    func summarizeCurrentPageAction() {
        guard AIFeatures.programEnabled else { return }
        let wv = activeWebView
        wv.evaluateJavaScript(SearxlyWebView.visibleTextExtractionScript) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let dict = result as? [String: Any]
                let text = (dict?["text"] as? String) ?? ""
                let title = (dict?["title"] as? String) ?? (wv.title ?? "")
                let urlStr = (dict?["url"] as? String) ?? (wv.url?.absoluteString ?? "")
                self.handleAskAISelection(text: text,
                                          actionRaw: AIChatSeed.Action.summarizePage.rawValue,
                                          title: title, url: urlStr)
            }
        }
    }

    /// Toggles Reader mode: extracts the current page's article (readability-lite, fully on-device)
    /// and presents it in the distraction-free ReaderView. A second invocation closes it.
    func toggleReaderModeAction() {
        if isReaderMode || !readerHTML.isEmpty {
            isReaderMode = false
            showingReaderSheet = false
            readerHTML = ""
            readerTitle = ""
            return
        }
        let wv = activeWebView
        guard wv.url != nil else { return }   // nothing loaded → nothing to read
        wv.evaluateJavaScript(ReaderExtraction.script) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let dict = result as? [String: Any],
                      let html = dict["html"] as? String, !html.isEmpty else { return }
                self.readerTitle = (dict["title"] as? String) ?? (wv.title ?? "")
                self.readerHTML = html
                self.isReaderMode = true
                self.showingReaderSheet = true
            }
        }
    }

    func showFindInPage() {
        showingFindBar = true
    }

    func performFindInPage(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        activeWebView.find(trimmed, configuration: config) { _ in }
    }

    func dismissFindInPage() {
        showingFindBar = false
        findSearchTerm = ""
        activeWebView.evaluateJavaScript("window.getSelection()?.removeAllRanges()")
    }
}
