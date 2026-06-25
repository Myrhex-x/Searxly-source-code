//
//  BrowserState+SiteNavigation.swift
//  Searxly
//
//  Tab/site actions: open URLs in tabs, bookmark, agentic openWebsite resolution.
//  Extracted from SearchCoordinator.swift.
//

import Foundation
import os
import SwiftUI
import WebKit

extension BrowserState {

    // MARK: - Tab actions

    /// Opens the given URL strings each in their own new browser tab (caps at 6).
    func openResultsInTabs(urls: [String]) {
        var opened = 0
        var lastOpened: BrowserTab?
        for raw in urls {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let withScheme = t.contains("://") ? t : "https://" + t
            guard let url = URL(string: withScheme) else { continue }
            if opened >= 6 { break }
            // .onion only works over Tor — route it through the dedicated onion-tab path.
            if url.isOnionService {
                openOnionURL(url)
                opened += 1
                continue
            }
            let tab = BrowserTab(initialURL: url)
            tabs.append(tab)
            lastOpened = tab
            opened += 1
        }
        if let last = lastOpened {
            selectedTabID = last.id
            showingWebContent = true
        }
    }

    /// Bookmarks a URL with an optional note. Dedupes by URL. Caps list at 200.
    func bookmarkWithNote(url: String, title: String, note: String?) {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        bookmarks.removeAll { $0.url == cleanURL }

        let baseTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (URL(string: cleanURL)?.host ?? "Untitled")
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayTitle: String
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            displayTitle = "\(baseTitle) — \(n)"
        } else {
            displayTitle = baseTitle
        }

        let item = BookmarkItem(url: cleanURL, title: displayTitle, note: note?.trimmingCharacters(in: .whitespacesAndNewlines))
        bookmarks.insert(item, at: 0)
        if bookmarks.count > 200 { bookmarks.removeLast(bookmarks.count - 200) }
        saveAllData()
    }

    /// Creates a new private (ephemeral) tab, sets the search query, and triggers a SearXNG-backed search.
    func createNewPrivateSearchTab(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tab = BrowserTab(privacyMode: .privateEphemeral, kind: .web)
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = false
        searchText = trimmed
        lastSearchQuery = trimmed

        Task { @MainActor in
            performSearchOrLoadInWebKit()
        }
    }

    // MARK: - Agentic site resolution

    /// Resolves a natural-language site description to a URL and opens it in a new tab.
    /// Uses OfficialEntityDatabase + private SearXNG. Falls back to a private search tab.
    func openWebsite(description: String) {
        let trimmed = cleanOpenDescription(description)
        guard !trimmed.isEmpty else { return }

        if let directURL = smartURL(from: trimmed) {
            openDirectWebsite(directURL, originalDescription: trimmed)
            return
        }

        if let trusted = SiteResolver.trustedURL(for: trimmed) {
            openDirectWebsite(trusted, originalDescription: trimmed)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let localMgr = LocalSearxngManager.shared
            if localMgr.projectFolderExists {
                let hasLocal = self.searxInstances.contains {
                    $0.url.hasPrefix("http://localhost:8080") || $0.url.hasPrefix("http://127.0.0.1:8080")
                }
                if hasLocal, !(await localMgr.isLocalWebReady()) {
                    await localMgr.ensureReadyAndRunning()
                }
            }

            let searchQuery = SiteResolver.resolutionQuery(for: trimmed)
            var opened = false
            var resolutionPath = "search+scored"

            do {
                let (res, _) = try await SearXNGService.shared.searchWithFallback(
                    query: searchQuery,
                    instances: self.searxInstances,
                    language: Localization.searchLanguageCode
                )

                let filteredForScorer = res.filter { r in
                    let host = (URL(string: r.url)?.host ?? r.url).lowercased()
                    let title = r.title.lowercased()
                    let isNews = host.contains("cnbc") || host.contains("bbc") || host.contains("nytimes") ||
                                 host.contains("reuters") || host.contains("bloomberg") || host.contains("forbes") ||
                                 host.contains("gizmodo") || host.contains("techcrunch") || host.contains("theverge") ||
                                 host.contains("arstechnica") || host.contains("wired") || host.contains("engadget") ||
                                 host.contains("mashable") || host.contains("businessinsider") ||
                                 (title.contains("news") && !title.contains("official"))
                    let isMetaXArticle = (title.contains("rebrand") || title.contains("formerly twitter") ||
                                          title.contains("x is") || title.contains("twitter rebrand")) &&
                                         !title.contains("official") &&
                                         (trimmed.lowercased() == "x" || trimmed.lowercased().contains("x twitter"))
                    return !isNews && !isMetaXArticle
                }

                if let best = SiteResolver.bestSafeCandidate(
                    for: trimmed,
                    from: filteredForScorer.map { (title: $0.title, url: $0.url) }
                ), best.shouldAutoOpen {
                    self.openDirectWebsite(best.url, originalDescription: trimmed)
                    opened = true
                    resolutionPath = "search+high-authority-scored"
                }
            } catch {
                // fall through to fallback
            }

            if !opened {
                self.createNewPrivateSearchTab(query: trimmed)
                resolutionPath = "fallback-search-tab"
            }

            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseSearXNGLogging {
                Log.web.info("[SiteResolver] openWebsite resolutionPath=\(resolutionPath) query=\(searchQuery) trimmed=\(trimmed) opened=\(opened)")
            }
        }
    }

    private func openDirectWebsite(_ url: URL, originalDescription: String) {
        clearNativeSearch()
        let tab = BrowserTab(initialURL: url)
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = true
        searchText = url.absoluteString
        lastSearchQuery = originalDescription
    }

    // MARK: - Onion (Tor) navigation

    /// Persisted one-time acknowledgement of the Tor disclosure.
    private static let torDisclosureAckKey = "Tor.HasAcknowledgedDisclosure"
    static var hasAcknowledgedTorDisclosure: Bool {
        get { UserDefaults.standard.bool(forKey: torDisclosureAckKey) }
        set { UserDefaults.standard.set(newValue, forKey: torDisclosureAckKey) }
    }

    /// Entry point for opening a `.onion` URL. On the user's FIRST onion ever, shows a one-time
    /// consent/disclosure sheet (what Tor does + does not protect) before connecting; afterwards it
    /// opens directly.
    func openOnionURL(_ url: URL) {
        guard Self.hasAcknowledgedTorDisclosure else {
            pendingOnionURL = url
            showTorDisclosure = true
            return
        }
        performOpenOnionURL(url)
    }

    /// User accepted the Tor disclosure — remember it and open the pending onion.
    func acknowledgeTorDisclosureAndContinue() {
        Self.hasAcknowledgedTorDisclosure = true
        showTorDisclosure = false
        if let url = pendingOnionURL {
            pendingOnionURL = nil
            performOpenOnionURL(url)
        }
    }

    /// User declined — drop the pending onion, open nothing.
    func cancelTorDisclosure() {
        showTorDisclosure = false
        pendingOnionURL = nil
    }

    /// Opens a `.onion` URL in a dedicated Tor-routed onion tab, bootstrapping Tor first.
    /// Onion tabs use an ephemeral data store whose traffic is proxied through the bundled Tor
    /// client (see WebViewFactory `.onion` + [TorManager]). A lightweight placeholder is shown while
    /// the circuit builds; the real navigation is issued only once Tor reports a ready circuit so the
    /// first request can't escape the proxy.
    private func performOpenOnionURL(_ url: URL) {
        clearNativeSearch()

        let tab = BrowserTab(privacyMode: .onion)
        tab.currentURL = url
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = true
        searchText = url.absoluteString

        // Validate the v3 onion address (the rightmost label must be 56 base32 chars). v2 onions are
        // dead and unsupported by Tor. Catch malformed addresses up front with a clear message rather
        // than a long, opaque connection timeout.
        let host = url.host?.lowercased() ?? ""
        let comps = host.split(separator: ".")
        let onionLabel = (comps.count >= 2 && comps.last == "onion") ? String(comps[comps.count - 2]) : ""
        let base32 = "abcdefghijklmnopqrstuvwxyz234567"
        let isValidV3 = onionLabel.count == 56 && onionLabel.allSatisfy { base32.contains($0) }
        guard isValidV3 else {
            tab.title = "Invalid onion address"
            tab.webView?.loadHTMLString(Self.onionStatusHTML(
                title: "Invalid onion address",
                detail: "This isn’t a valid v3 onion address (56 characters ending in .onion). Check it and try again."),
                baseURL: nil)
            return
        }

        tab.title = "Connecting to Tor…"
        // Immediate local feedback (no network) while the circuit bootstraps. baseURL = the onion URL
        // so the address bar shows the real .onion address (not about:blank) during connection.
        tab.webView?.loadHTMLString(Self.onionStatusHTML(title: "Connecting to Tor…",
                                                          detail: "Building a circuit to reach this hidden service."),
                                    baseURL: url)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await TorManager.shared.ensureReadyAndRunning()

            // Bail if the tab was closed while we waited.
            guard self.tabs.contains(where: { $0.id == tab.id }) else { return }

            if ready {
                tab.title = url.host ?? "Onion site"
                tab.webView?.load(URLRequest(url: url))
            } else {
                let msg = TorManager.shared.lastError ?? "Could not connect to Tor."
                tab.title = "Tor unavailable"
                tab.webView?.loadHTMLString(Self.onionStatusHTML(title: "Couldn’t connect to Tor",
                                                                 detail: msg),
                                            baseURL: nil)
            }
        }
    }

    /// Stops Tor once no onion tabs remain — resource + privacy hygiene. Safe to call often; no-ops
    /// when an onion tab is still open or Tor is already stopped/stopping. Call after any tab removal.
    func stopTorIfNoOnionTabsRemain() {
        guard !tabs.contains(where: { $0.privacyMode == .onion }) else { return }
        switch TorManager.shared.status {
        case .stopped, .stopping:
            return
        default:
            Task { @MainActor in await TorManager.shared.stop() }
        }
    }

    /// Minimal monochrome status page shown inside an onion tab while Tor connects (or on failure).
    /// Adapts to light/dark via `prefers-color-scheme`; brand stays black & white.
    private static func onionStatusHTML(title: String, detail: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;")
        let safeDetail = detail.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          html,body{height:100%;margin:0}
          body{display:flex;align-items:center;justify-content:center;
               font:-apple-system-body, -apple-system, system-ui, sans-serif;
               background:#fff;color:#111}
          @media (prefers-color-scheme: dark){ body{background:#0a0a0a;color:#f2f2f2} }
          .card{max-width:440px;padding:32px;text-align:center}
          .glyph{font-size:34px;letter-spacing:6px;opacity:.85;margin-bottom:18px}
          h1{font-size:18px;font-weight:600;margin:0 0 8px}
          p{font-size:13px;line-height:1.5;opacity:.7;margin:0}
          .note{margin-top:22px;font-size:11px;opacity:.5}
        </style></head>
        <body><div class="card">
          <div class="glyph">⠿</div>
          <h1>\(safeTitle)</h1>
          <p>\(safeDetail)</p>
          <p class="note">Tor hides your IP and reaches .onion services. This is not Tor Browser and
          does not provide its full anti-fingerprinting protection.</p>
        </div></body></html>
        """
    }

    // MARK: - Onion-Location (auto-detected .onion mirrors)

    /// The offer to surface — but only while it still applies to the page on screen, so the banner
    /// auto-hides when the user navigates away (host changes) without any explicit clearing.
    var activeOnionLocationOffer: OnionLocationOffer? {
        guard let offer = onionLocationOffer else { return nil }
        let currentHost = (webCurrentURL ?? selectedTab?.currentURL)?.host?.lowercased()
        return offer.pageHost == currentHost ? offer : nil
    }

    /// Records a detected Onion-Location mirror for the current page. Ignored on onion tabs and for
    /// non-.onion targets.
    func noteOnionLocation(_ onionURL: URL, forPageHost host: String) {
        guard selectedTab?.privacyMode != .onion, onionURL.isOnionService else { return }
        onionLocationOffer = OnionLocationOffer(pageHost: host.lowercased(), onionURL: onionURL)
    }

    /// Opens the offered `.onion` mirror in a Tor-routed onion tab.
    func acceptOnionLocationOffer() {
        guard let offer = onionLocationOffer else { return }
        onionLocationOffer = nil
        openOnionURL(offer.onionURL)
    }

    func dismissOnionLocationOffer() {
        onionLocationOffer = nil
    }

    // MARK: - Helpers

    private func cleanOpenDescription(_ input: String) -> String {
        var desc = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return "" }

        let lower = desc.lowercased()
        let prefixesToStrip = [
            "open the ", "open ",
            "go to the ", "go to ",
            "visit the ", "visit ",
            "take me to the ", "take me to ",
            "the "
        ]
        for prefix in prefixesToStrip {
            if lower.hasPrefix(prefix) {
                desc = String(desc.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        let fluffSuffixesAndInfixes = [
            " official website", " official site", " official homepage", " official web site",
            "'s official website", "'s official site", "'s official homepage",
            " website", " site", " homepage", " web page", " page",
            "'s", " elon musk", " musk", " elon"
        ]
        var lower2 = desc.lowercased()
        for term in fluffSuffixesAndInfixes {
            if lower2.hasSuffix(term) {
                desc = String(desc.dropLast(term.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                lower2 = desc.lowercased()
            }
            if let range = desc.range(of: term, options: .caseInsensitive) {
                desc = (desc[..<range.lowerBound] + desc[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                lower2 = desc.lowercased()
            }
        }

        let facilityTerms = [" chip facility", " chip fab", " fab", " supercluster", " super cluster",
                             " cluster", " facility", " project", " gigafactory"]
        for t in facilityTerms {
            if let range = desc.range(of: t, options: .caseInsensitive) {
                desc = (desc[..<range.lowerBound] + desc[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lowerDesc = desc.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerDesc == "x" || lowerDesc == "twitter" ||
           lowerDesc.contains("x twitter") || lowerDesc.contains("x rebrand") ||
           lowerDesc.contains("formerly twitter") || lowerDesc.contains("x (twitter)") ||
           lowerDesc.hasPrefix("x ") || lowerDesc.contains(" x ") {
            desc = "x.com"
        }

        return desc.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
