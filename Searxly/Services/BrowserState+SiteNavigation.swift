//
//  BrowserState+SiteNavigation.swift
//  Searxly
//
//  Tab/site actions: open URLs in tabs, bookmark, agentic openWebsite resolution.
//  Extracted from SearchCoordinator.swift.
//

import AppKit
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers
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
        if bookmarks.count > BookmarkLimits.maxCount { bookmarks.removeLast(bookmarks.count - BookmarkLimits.maxCount) }
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

    // MARK: - Local file opening ("Open File…", ⌘O)

    /// Presents an open panel so the user can view a local HTML file — or a whole web-project folder — in
    /// a new tab. This is the only sandbox-legal way in: a file:// path typed in the address bar grants no
    /// read access, but a file/folder chosen here comes with a security-scoped grant we hold for the tab's
    /// lifetime. Picking a **folder** is the recommended path for real projects — its index.html opens and
    /// every sibling asset (CSS/JS/images) is readable. Picking a single file also works, though same-folder
    /// assets it references may not load under the App Sandbox (the grant covers only the chosen file).
    func openLocalFile() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.message = "Choose an HTML file to open — or a folder (its index.html opens, with all its assets)."
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.html]

        guard panel.runModal() == .OK, let picked = panel.url else { return }

        // Hold the sandbox grant while we inspect the pick (the index.html lookup reads the folder).
        // The tab below takes its own long-lived grant; this local one is balanced by the defer.
        let didStart = picked.startAccessingSecurityScopedResource()
        defer { if didStart { picked.stopAccessingSecurityScopedResource() } }

        // Resolve the file to load and the URL WebKit may read from:
        //  • folder picked → open its index.html (or first *.html); read access = the folder.
        //  • file picked   → open it directly; read access = the file ITSELF (see below).
        let isDirectory = (try? picked.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let fileToLoad: URL
        let readAccessURL: URL
        if isDirectory {
            guard let entry = Self.firstHTMLFile(in: picked) else {
                Self.presentNoHTMLFileAlert(for: picked)
                return
            }
            fileToLoad = entry
            readAccessURL = picked
        } else {
            fileToLoad = picked
            // Read access MUST be a path the sandbox actually granted us. NSOpenPanel extends the grant to
            // the exact selection only — the chosen file, NOT its parent folder. Passing the parent here
            // (which we hold no security scope for) means WebKit can't mint the read sandbox-extension for
            // the WebContent process, and the page loads blank. Grant access to the file itself so it
            // renders. (Same-folder assets it references still won't load — pick the enclosing FOLDER to
            // view a project with its CSS/JS/images.)
            readAccessURL = picked
        }

        // Fresh foreground tab that holds the security scope (on the URL the panel actually granted) for
        // its whole lifetime, then loads the local page.
        clearNativeSearch()
        let tab = BrowserTab(kind: .web)
        tab.retainSecurityScopedAccess(to: picked)
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = true
        searchText = fileToLoad.absoluteString
        loadLocalFileInWebView(fileToLoad, readAccessURL: readAccessURL, recordInHistory: false)
    }

    /// Opens a local `file://` URL that arrived from outside the address bar — "Open With Searxly" /
    /// double-click / drag onto the Dock icon (delivered via `.onOpenURL`), or a file dragged onto the
    /// window. Opens it in a fresh foreground tab and retains any security-scoped access for the tab's
    /// lifetime so WebKit can read the bytes. (Files handed over by Finder/LaunchServices arrive with a
    /// grant that isn't a scoped-bookmark URL, so `retainSecurityScopedAccess` is a harmless no-op there —
    /// the grant already covers the load; drag-and-drop DOES yield a scoped URL, which we then hold.)
    func openLocalFileURL(_ url: URL) {
        guard url.isFileURL else { return }
        clearNativeSearch()
        let tab = BrowserTab(kind: .web)
        tab.retainSecurityScopedAccess(to: url)
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = true
        searchText = url.absoluteString
        // Read access = the file itself: we hold a grant for exactly this file, not its parent folder
        // (see loadLocalFileInWebView / openLocalFile for the sandbox rationale).
        loadLocalFileInWebView(url, readAccessURL: url, recordInHistory: false)
    }

    /// Finds the entry HTML file in a picked folder: index.html / index.htm if present, otherwise the
    /// first *.html/*.htm file (shallow, alphabetical for determinism). nil if the folder has none.
    private static func firstHTMLFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        for name in ["index.html", "index.htm"] {
            let candidate = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    private static func presentNoHTMLFileAlert(for folder: URL) {
        let alert = NSAlert()
        alert.messageText = "No HTML file found"
        alert.informativeText = "“\(folder.lastPathComponent)” doesn’t contain an index.html (or any .html file) to open."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    /// Entry point for opening a `.onion` URL. Onion routing is opt-in in the base app
    /// (TorManager.isEnabled, off by default). When it's off, a quick "Enable Tor?" prompt is shown.
    ///
    /// Searxly Maximum always keeps Tor available — including while Maximum Privacy rides the
    /// **Searxly VPN** lane. .onion hosts only resolve over Tor's SOCKS (SOCKS5h); a live VPN alone
    /// can't open them. So Maximum never prompts: it enables Tor and opens a dedicated onion tab,
    /// leaving clearnet on the VPN while the onion tab exits through Tor (typically Tor-over-VPN).
    func openOnionURL(_ url: URL) {
        if Edition.isMaximum {
            TorManager.shared.isEnabled = true
            performOpenOnionURL(url)
            return
        }
        guard TorManager.shared.isEnabled else {
            pendingOnionURL = url
            showTorDisclosure = true
            return
        }
        performOpenOnionURL(url)
    }

    /// User chose to enable Tor from the prompt — turn it on and open the pending onion.
    func enableTorAndOpenPending() {
        TorManager.shared.isEnabled = true
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
        // so the address bar shows the real .onion address (not about:blank) during connection. The
        // marker lets the watchdog below detect "still on the placeholder" (a real onion page won't have it).
        tab.webView?.loadHTMLString(Self.onionStatusHTML(title: "Connecting to Tor…",
                                                          detail: "Building a circuit to reach this hidden service.",
                                                          marker: "connecting"),
                                    baseURL: url)

        Task { @MainActor [weak self] in
            guard let self else { return }
            Log.tor.info("[onion] preparing to load \(url.host ?? "?", privacy: .public) — ensuring Tor is ready")
            let ready = await TorManager.shared.ensureReadyAndRunning()

            // Bail if the tab was closed while we waited.
            guard self.tabs.contains(where: { $0.id == tab.id }) else { return }

            guard ready else {
                let msg = TorManager.shared.lastError ?? "Could not connect to Tor."
                Log.tor.error("[onion] Tor not ready: \(msg, privacy: .public)")
                tab.title = "Tor unavailable"
                tab.webView?.loadHTMLString(Self.onionStatusHTML(title: "Couldn’t connect to Tor",
                                                                 detail: msg),
                                            baseURL: nil)
                return
            }

            guard let wv = tab.webView else {
                // Onion tabs no longer hibernate, but guard anyway: a nil webView would make load() a
                // silent no-op and strand the tab on the placeholder forever.
                Log.tor.error("[onion] Tor ready but onion tab has no webView — cannot load \(url.absoluteString, privacy: .public)")
                return
            }

            Log.tor.info("[onion] Tor ready — issuing load for \(url.host ?? "?", privacy: .public)")
            tab.title = url.host ?? "Onion site"
            var request = URLRequest(url: url)
            request.timeoutInterval = 45   // fail cleanly instead of spinning if the circuit stalls
            wv.load(request)
            self.scheduleOnionLoadWatchdog(for: tab, url: url)
        }
    }

    /// Safety net so an onion tab can never sit on the "Connecting to Tor…" placeholder forever. If the
    /// real page hasn't replaced the placeholder within the window, show an unreachable page. Detects
    /// "still placeholder" via the marker on the local placeholder document — a committed onion page
    /// won't carry it. This converts any silent stall (whatever its cause) into a clear, recoverable state.
    private func scheduleOnionLoadWatchdog(for tab: BrowserTab, url: URL) {
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, let tab,
                  self.tabs.contains(where: { $0.id == tab.id }),
                  let wv = tab.webView else { return }

            let stillConnecting: Bool = await withCheckedContinuation { cont in
                wv.evaluateJavaScript("!!(document.body && document.body.getAttribute('data-searxly-onion') === 'connecting')") { result, _ in
                    cont.resume(returning: (result as? Bool) ?? false)
                }
            }
            guard stillConnecting else { return }

            Log.tor.error("[onion] still on the connecting placeholder after 30s — treating as unreachable: \(url.absoluteString, privacy: .public)")
            tab.title = "Onion unavailable"
            wv.loadHTMLString(Self.onionStatusHTML(
                title: "Couldn’t reach this onion",
                detail: "Tor connected, but \(url.host ?? "this hidden service") didn’t respond. It may be offline, or the address may be wrong — try reloading."),
                baseURL: url)
        }
    }

    /// Stops Tor once no onion tabs remain — resource + privacy hygiene. Safe to call often; no-ops
    /// when an onion tab is still open or Tor is already stopped/stopping. Call after any tab removal.
    ///
    /// **Never** tear Tor down while Maximum Privacy is on the Tor kill-switch lane: Tor is carrying
    /// every tab and every search, not just onion tabs. Stopping it here was the classic failure where
    /// closing the last .onion (or never opening one) left the kill switch closed — "VPN or Tor isn't
    /// connected" — even if the user had a VPN tunnel up that the gate was still ignoring.
    ///
    /// On the VPN protection lane, Tor is only needed for onion tabs, so it still stops when the last
    /// onion tab closes (and will start again the next time someone opens a .onion).
    func stopTorIfNoOnionTabsRemain() {
        guard !tabs.contains(where: { $0.privacyMode == .onion }) else { return }
        if PrivacyManager.shared.appPrivacyMode == .maximum,
           PrivacyManager.shared.maxProtection == .tor {
            return
        }
        switch TorManager.shared.status {
        case .stopped, .stopping:
            return
        default:
            Task { @MainActor in await TorManager.shared.stop() }
        }
    }

    /// Called when Tor is switched off while onion tabs are open. Each onion tab can no longer reach its
    /// hidden service, so we swap its content for a "Tor is off" page — keeping the onion URL as the base
    /// so a reload reconnects once Tor is switched back on.
    func handleTorDisabled() {
        for tab in tabs where tab.privacyMode == .onion {
            tab.webView?.loadHTMLString(
                Self.onionStatusHTML(
                    title: "Tor is off",
                    detail: "Onion sites only work over Tor. Turn Tor back on from the Tor button, then reload this tab to reconnect."),
                baseURL: tab.webView?.url)
        }
    }

    /// Minimal monochrome status page shown inside an onion tab while Tor connects (or on failure).
    /// Adapts to light/dark via `prefers-color-scheme`; brand stays black & white.
    /// - Parameter marker: when set, stamped on `<body data-searxly-onion="…">` so the onion load
    ///   watchdog can tell a still-showing placeholder from a real onion page that has committed.
    private static func onionStatusHTML(title: String, detail: String, marker: String? = nil) -> String {
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;")
        let safeDetail = detail.replacingOccurrences(of: "<", with: "&lt;")
        let bodyAttr = marker.map { " data-searxly-onion=\"\($0)\"" } ?? ""
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
        <body\(bodyAttr)><div class="card">
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

    /// Records a detected Onion-Location mirror for the current page. Ignored on onion tabs, non-.onion
    /// targets, and onions already found dead (so abandoned mirrors like X's stop nagging).
    func noteOnionLocation(_ onionURL: URL, forPageHost host: String) {
        guard selectedTab?.privacyMode != .onion, onionURL.isOnionService else { return }
        guard let oh = onionURL.host?.lowercased(), !Self.deadOnionHosts.contains(oh) else { return }
        let pageHost = host.lowercased()

        // Auto-upgrade: switch straight to the .onion mirror instead of just offering it (onion
        // services are end-to-end encrypted with no exit node). Default-on in Maximum. Guard against
        // loops by upgrading each page host at most once per session, and only when Tor is enabled
        // (otherwise the "Enable Tor?" prompt would fire unexpectedly on a normal page load).
        if OnionPreferences.autoUpgrade, TorManager.shared.isEnabled,
           !Self.autoUpgradedHostsThisSession.contains(pageHost) {
            Self.autoUpgradedHostsThisSession.insert(pageHost)
            onionLocationOffer = nil
            performOpenOnionURL(onionURL)
            return
        }

        onionLocationOffer = OnionLocationOffer(pageHost: pageHost, onionURL: onionURL)
    }

    /// Page hosts already auto-upgraded to their .onion this session, so we don't re-trigger a new
    /// onion tab every time the clearnet page reloads. Process-lifetime; not persisted.
    private static var autoUpgradedHostsThisSession: Set<String> = []

    /// Opens the offered `.onion` mirror in a Tor-routed onion tab.
    func acceptOnionLocationOffer() {
        guard let offer = onionLocationOffer else { return }
        onionLocationOffer = nil
        openOnionURL(offer.onionURL)
    }

    func dismissOnionLocationOffer() {
        onionLocationOffer = nil
    }

    /// Onion hosts that failed to load, so their Onion-Location banner is never auto-offered again.
    /// Many sites (e.g. X) advertise an onion they've since abandoned, and onion liveness can't be
    /// known without connecting — so we suppress reactively after the first failed attempt.
    private static let deadOnionsKey = "Tor.DeadOnionHosts"
    static var deadOnionHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: deadOnionsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: deadOnionsKey) }
    }

    /// Marks an onion host unreachable (called when an onion tab fails to load) and drops any live
    /// offer for it.
    func markOnionUnreachable(_ host: String) {
        let h = host.lowercased()
        guard h.hasSuffix(".onion") else { return }
        var set = Self.deadOnionHosts
        set.insert(h)
        Self.deadOnionHosts = set
        if onionLocationOffer?.onionURL.host?.lowercased() == h { onionLocationOffer = nil }
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
