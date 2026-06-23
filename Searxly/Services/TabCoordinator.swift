//
//  TabCoordinator.swift
//  Searxly
//
//  Tab lifecycle, sidebar, session persistence, and vault tab management.
//

import Foundation
import os
import SwiftUI
import WebKit

extension BrowserState {
    func loadPersistedData(hasCompletedOnboardingBinding: Binding<Bool>? = nil) {
        let data = Persistence.load()

        if !data.searxInstances.isEmpty {
            searxInstances = data.searxInstances
        }

        history = data.history
        bookmarks = data.bookmarks

        // Phase 0: aiPreferences now lives in AppData (encrypted when user has encryption on).
        // The LocalIntelligenceManager currently seeds from UserDefaults for the master flag during scaffolding;
        // a future micro-patch will sync the full AIPreferences struct from here into the manager.
        _ = data.aiPreferences   // ensures the field is exercised on every load (safe, no-op today)

        if let savedIDString = data.currentInstanceID,
           let savedID = UUID(uuidString: savedIDString),
           searxInstances.contains(where: { $0.id == savedID }) {
            currentInstanceID = savedID
        } else if let first = searxInstances.first {
            currentInstanceID = first.id
        } else {
            // No instances → force onboarding (caller updates the @AppStorage binding)
            if let binding = hasCompletedOnboardingBinding {
                binding.wrappedValue = false
            }
        }

        // Stale opt-in from a prior partial setup must not re-enable background auto-start on next launch.
        if let binding = hasCompletedOnboardingBinding, !binding.wrappedValue {
            UserDefaults.standard.removeObject(forKey: "Searxly.LocalSearxng.UserOptedIn")
        }

        // Auto-recovery: if the local SearXNG setup folder exists (from previous onboarding or manual),
        // but the instance entry is missing (e.g. due to previous AppData decode/backup issues),
        // auto-add the standard localhost entry so the UI doesn't think "no instance".
        let localMgr = LocalSearxngManager.shared
        Task { @MainActor in
            await localMgr.updateProjectFolderExists()
            if localMgr.projectFolderExists {
                let localURL = localMgr.defaultLocalInstanceURL
                let localhostURLs = ["http://127.0.0.1:8080", "http://localhost:8080"]
                if !self.searxInstances.contains(where: { inst in
                    localhostURLs.contains { inst.url.hasPrefix($0) }
                }) {
                    let localInst = SearXNGInstance(name: "Local", url: localURL)
                    self.searxInstances.append(localInst)
                    if self.currentInstanceID == UUID() || !self.searxInstances.contains(where: { $0.id == self.currentInstanceID }) {
                        self.currentInstanceID = localInst.id
                    }
                    self.saveAllData()
                }
            }
        }

        // Background warm-up only for returning users who finished onboarding.
        if localMgr.mayAutoStartLocalContainer {
            localMgr.scheduleLaunchWarmUp()
        }

        // Sidebar free-resize preference (lightweight, separate from encrypted AppData).
        loadSidebarPreferences()

        // One-time purge of "search history" (past queries typed in the address bar that used to be
        // suggested). Per explicit user request to remove search history from the address bar.
        // We only ever kept lastSearchQuery + the AI attachment key for non-suggestion uses
        // (results header, Local AI grounding). This does NOT clear the full browsing `history`
        // list (that's separate, shown in BookmarksHistoryView, and cleared via Clear Data or the view).
        // The flag ensures this only runs once.
        let searchHistoryPurgedKey = "Searxly.SearchHistoryPurged_v1"
        if !UserDefaults.standard.bool(forKey: searchHistoryPurgedKey) {
            lastSearchQuery = ""
            UserDefaults.standard.set(true, forKey: searchHistoryPurgedKey)
        }

        // Listen for direct (url, title) snapshots from WebViewRepresentable coordinators.
        // This gives us an atomic view of the live WKWebView at KVO/didFinish time for reliable
        // history title repair (the root cause of crossed "Youtube - speedtest.com" suggestions).
        if !historyTitleObserverRegistered {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleHistoryTitleSnapshot(_:)),
                name: Self.historyTitleSnapshotNotification,
                object: nil
            )
            historyTitleObserverRegistered = true
        }
    }

    func saveAllData() {
        // Load current to preserve fields owned by other managers (vpnProfiles, tabSnapshots, appLock*,
        // hibernation config, etc.). We only override the fields this state directly owns.
        var data = Persistence.load()
        data.searxInstances = searxInstances
        data.history = history
        data.bookmarks = bookmarks
        data.currentInstanceID = currentInstanceID.uuidString
        Persistence.save(data)
    }

    /// Single-call save for app termination. Writes tabs + all state in one Persistence.save(),
    /// resulting in exactly one keychain read rather than one per save function called on quit.
    func saveAllDataIncludingSession() {
        var data = Persistence.load()
        data.tabSnapshots = tabs.map { TabSnapshot(from: $0) }
        data.searxInstances = searxInstances
        data.history = history
        data.bookmarks = bookmarks
        data.currentInstanceID = currentInstanceID.uuidString
        Persistence.save(data)
    }

    // MARK: - Sidebar width (free drag resize)

    func loadSidebarPreferences() {
        let w = UserDefaults.standard.double(forKey: sidebarWidthKey)
        if w > 0 {
            if w <= Self.collapseThreshold {
                sidebarWidth = Self.railWidth
            } else {
                sidebarWidth = max(Self.defaultExpandedWidth, CGFloat(w))
            }
            isSidebarCollapsed = sidebarWidth <= Self.collapseThreshold
        }
        let lw = UserDefaults.standard.double(forKey: lastExpandedSidebarWidthKey)
        if lw > Self.collapseThreshold {
            lastExpandedSidebarWidth = CGFloat(lw)
        }
        if lastExpandedSidebarWidth < 180 {
            lastExpandedSidebarWidth = Self.defaultExpandedWidth
        }
    }

    func saveSidebarPreferences() {
        UserDefaults.standard.set(sidebarWidth, forKey: sidebarWidthKey)
        UserDefaults.standard.set(lastExpandedSidebarWidth, forKey: lastExpandedSidebarWidthKey)
    }

    /// Sets the sidebar width (only ever the rail or a comfortable expanded value via toggle).
    func setSidebarWidth(_ w: CGFloat) {
        let target = (w <= Self.collapseThreshold) ? Self.railWidth : max(Self.defaultExpandedWidth, w)
        sidebarWidth = target
        if target > Self.collapseThreshold {
            lastExpandedSidebarWidth = target
        }
        isSidebarCollapsed = (target <= Self.collapseThreshold)
        saveSidebarPreferences()
    }

    /// Snap helper used by the chevron buttons in the sidebar.
    /// If currently wide, collapses to canonical rail and remembers the prior width.
    /// If narrow, restores to the last comfortable expanded width (or default).
    func toggleSidebarCollapse() {
        if sidebarWidth > Self.collapseThreshold {
            lastExpandedSidebarWidth = sidebarWidth
            setSidebarWidth(Self.railWidth)
        } else {
            let target = (lastExpandedSidebarWidth > Self.collapseThreshold) ? lastExpandedSidebarWidth : Self.defaultExpandedWidth
            setSidebarWidth(target)
        }
    }


    // MARK: - Password Vault (web page integration)

    func fillCurrentPageWithLogin(username: String, password: String) {
        guard PasswordVaultManager.shared.autofillEnabled else { return }
        // callAsyncJavaScript passes arguments as proper JSON-encoded named parameters so
        // no manual escaping is needed — passwords with backticks, ${ } or other special
        // characters cannot break out of the JS context.
        let js = """
        (function() {
            function fillField(el, value) {
                try {
                    const desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    if (desc && desc.set) { desc.set.call(el, value); }
                    else { el.value = value; }
                } catch(e) { el.value = value; }
                el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                el.dispatchEvent(new Event('blur', { bubbles: true }));
            }
            const inputs = document.getElementsByTagName('input');
            let userField = null;
            let passField = null;
            for (let i = 0; i < inputs.length; i++) {
                const inp = inputs[i];
                const name = (inp.name || '').toLowerCase();
                const id = (inp.id || '').toLowerCase();
                const type = (inp.type || 'text').toLowerCase();
                if (!userField && (type === 'text' || type === 'email' || type === 'tel' ||
                    /user|email|login|username/i.test(name) || /user|email|login|username/i.test(id))) {
                    userField = inp;
                }
                if (type === 'password') { passField = inp; }
            }
            if (userField) { fillField(userField, username); }
            if (passField) { fillField(passField, password); }
        })();
        """
        activeWebView.callAsyncJavaScript(js,
                                          arguments: ["username": username, "password": password],
                                          in: nil,
                                          in: .page,
                                          completionHandler: nil)
    }

    /// Fills only password field(s) on the current page. Used for "generate password directly here" flows
    /// on signup / create-account pages (no username required).
    func fillCurrentPageWithPassword(_ password: String) {
        guard PasswordVaultManager.shared.suggestPasswordsEnabled else { return }
        let js = """
        (function() {
            const passFields = document.querySelectorAll('input[type="password"]');
            if (passFields.length === 0) return;
            let target = passFields[0];
            for (let f of passFields) {
                if ((f.value || '').trim() === '') {
                    target = f;
                    break;
                }
            }
            target.value = password;
            target.dispatchEvent(new Event('input', { bubbles: true }));
            target.dispatchEvent(new Event('change', { bubbles: true }));
        })();
        """
        activeWebView.callAsyncJavaScript(js,
                                          arguments: ["password": password],
                                          in: nil,
                                          in: .page,
                                          completionHandler: nil)
    }

    /// Generates a strong password (using the vault's built-in AI suggest or local generator)
    /// and immediately fills it into the password field(s) on the current web page.
    /// This lets users create passwords "directly in the browser" without leaving the page.
    func generateAndFillPasswordOnCurrentPage() {
        guard PasswordVaultManager.shared.suggestPasswordsEnabled else { return }

        Task { @MainActor in
            let domain = currentWebDomain ?? ""
            let password = await PasswordVaultManager.shared.suggestPasswordWithAI(for: domain)

            fillCurrentPageWithPassword(password)

            if PasswordVaultManager.shared.copyGeneratedToClipboard {
                PasswordVaultManager.shared.copyGeneratedPasswordToClipboard(password)
            }

            // The PasswordVaultManager will handle any transient feedback if we want to surface it,
            // but for direct browser generation the visible fill + clipboard is the main effect.
        }
    }

    /// Switches to a web tab for the given domain (if one exists) and fills login fields.
    func fillLoginForDomain(domain: String, username: String, password: String) {
        guard PasswordVaultManager.shared.autofillEnabled else { return }

        let normalized = PasswordVaultManager.normalizeDomain(domain)

        if let matchingTab = tabs.first(where: { tab in
            guard tab.kind == .web, let host = tab.currentURL?.host?.lowercased() else { return false }
            let tabDomain = PasswordVaultManager.normalizeDomain(host)
            return tabDomain == normalized || host.contains(normalized) || normalized.contains(tabDomain)
        }) {
            selectedTabID = matchingTab.id
            showingWebContent = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                fillCurrentPageWithLogin(username: username, password: password)
            }
            return
        }

        if let url = URL(string: "https://\(normalized)") {
            loadInWebView(url)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                fillCurrentPageWithLogin(username: username, password: password)
            }
        }
    }

    /// Reads username/password from visible form fields on the current web page.
    func extractCredentialsFromCurrentPage(completion: @escaping (String, String) -> Void) {
        let js = """
        (function() {
            const inputs = document.getElementsByTagName('input');
            let userField = null;
            let passField = null;
            for (let i = 0; i < inputs.length; i++) {
                const inp = inputs[i];
                const name = (inp.name || '').toLowerCase();
                const id = (inp.id || '').toLowerCase();
                if (!userField && (inp.type === 'text' || inp.type === 'email' || /user|email|login|username/i.test(name) || /user|email|login|username/i.test(id))) {
                    userField = inp;
                }
                if (inp.type === 'password') {
                    passField = inp;
                }
            }
            return JSON.stringify({
                username: userField ? (userField.value || '') : '',
                password: passField ? (passField.value || '') : ''
            });
        })();
        """

        activeWebView.evaluateJavaScript(js) { result, _ in
            Task { @MainActor in
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    completion(dict["username"] ?? "", dict["password"] ?? "")
                } else {
                    completion("", "")
                }
            }
        }
    }

    /// Light detection for pages that are asking for a password.
    /// Sets observable flags so the pill can show contextual "generate directly here" actions.
    /// Also posts the offer notification (debounced per domain) for save flows.
    ///
    /// Detects both normal login forms and "make a password" / signup / create-account flows.
    func checkForLoginFormAndOfferSave() {
        let js = """
        (function() {
          const passFields = Array.from(document.querySelectorAll('input[type="password"]'));
          if (passFields.length === 0) {
            return JSON.stringify({ has: false, creation: false });
          }

          let isCreation = false;
          const pageText = (document.body ? document.body.innerText : '').toLowerCase();
          const docTitle = (document.title || '').toLowerCase();

          for (const f of passFields) {
            const sig = ((f.name || '') + ' ' + (f.id || '') + ' ' + (f.placeholder || '') + ' ' + (f.getAttribute('aria-label') || '')).toLowerCase();
            if (sig.includes('new') || sig.includes('create') || sig.includes('confirm') || 
                sig.includes('repeat') || sig.includes('signup') || sig.includes('register')) {
              isCreation = true;
            }
          }

          if (!isCreation) {
            if (pageText.includes('create account') || pageText.includes('sign up') || 
                pageText.includes('register') || pageText.includes('join now') || 
                pageText.includes('new password') || pageText.includes('choose a password') ||
                docTitle.includes('sign up') || docTitle.includes('register') || docTitle.includes('create account')) {
              isCreation = true;
            }
          }

          return JSON.stringify({ has: true, creation: isCreation });
        })();
        """

        activeWebView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let has = (dict["has"] as? Bool) ?? false
            let creation = (dict["creation"] as? Bool) ?? false

            self.currentPageHasPasswordField = has
            self.currentPageIsLikelyPasswordCreation = creation

            guard has else { return }

            guard PasswordVaultManager.shared.offerToSaveEnabled else { return }

            // Debounced offer notification (for save flows)
            let domain = self.currentWebDomain ?? ""
            if domain != self.lastOfferedSaveDomain {
                self.lastOfferedSaveDomain = domain
                NotificationCenter.default.post(name: Notification.Name("Searxly.OfferSaveLogin"), object: nil, userInfo: ["domain": domain])
            }
        }
    }
    func ensureAndSelectPasswordsVaultTab() {
        if let existing = tabs.first(where: { $0.kind == .passwords }) {
            selectedTabID = existing.id
            showingWebContent = false
            return
        }

        let vaultTab = BrowserTab(space: .personal, kind: .passwords)
        tabs.append(vaultTab)
        selectedTabID = vaultTab.id
        showingWebContent = false
        // The vault tab does not participate in hibernation or auto-cleanup (enforced by kind checks elsewhere).
        #if DEBUG
        Log.web.info("[Passwords] Created and selected in-app password vault tab.")
        #endif
    }
    // Tab management (sidebar actions call these)
    func newTab() {
        let newTab = BrowserTab(kind: .web)
        tabs.append(newTab)
        selectedTabID = newTab.id
        showingWebContent = false
        searchText = ""
        clearNativeSearch()
        saveCurrentSession()   // Persist the new blank tab immediately for reliable session state across launches
    }

    func newPrivateTab() {
        let newTab = BrowserTab(privacyMode: .privateEphemeral, kind: .web)
        tabs.append(newTab)
        selectedTabID = newTab.id
        showingWebContent = false
        searchText = ""
        clearNativeSearch()
        saveCurrentSession()   // Persist the new private tab immediately
    }

    func closeTab(_ tab: BrowserTab) {
        // Pause media *before* we remove the tab from the array. When the last strong ref
        // to the BrowserTab disappears, its webView is released; we want the pause JS to
        // have run while the webView is still alive and attached to a WebContent process.
        if tab.kind == .web {
            tab.pauseAllMediaForClose()
        }

        // Save a snapshot for "Reopen Closed Tab" (only web tabs with a URL are useful to restore)
        if tab.kind == .web, let url = tab.currentURL, !url.absoluteString.isEmpty {
            let snapshot = TabSnapshot(from: tab)
            recentlyClosedSnapshots.insert(snapshot, at: 0)
            if recentlyClosedSnapshots.count > 15 {
                recentlyClosedSnapshots.removeLast()
            }
        }

        guard tabs.count > 1 else {
            // Reset to a fresh web tab.
            tabs[0] = BrowserTab(kind: .web)
            selectedTabID = tabs[0].id
            showingWebContent = false
            searchText = ""
            clearNativeSearch()
            saveCurrentSession()   // Persist immediately so closing the last tab (e.g. speedtest) doesn't resurrect on next launch
            return
        }
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            let wasSelected = selectedTabID == tab.id
            tabs.remove(at: index)
            if wasSelected {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
                if let u = tabs[newIndex].currentURL {
                    searchText = u.absoluteString
                    showingWebContent = true
                } else {
                    showingWebContent = false
                }
            }
            saveCurrentSession()   // Persist tab list right away — prevents stale sessions (e.g. speedtest) from reappearing after close
        }
    }

    /// Reopens the most recently closed tab. No-op if the history is empty.
    func reopenLastClosedTab() {
        guard let snapshot = recentlyClosedSnapshots.first else { return }
        recentlyClosedSnapshots.removeFirst()
        guard let url = URL(string: snapshot.url) else { return }
        let tab = BrowserTab(initialURL: url, privacyMode: snapshot.privacyMode, space: snapshot.space, kind: .web)
        tab.isPinned = snapshot.isPinned
        tabs.append(tab)
        selectedTabID = tab.id
        loadInWebView(url)
    }

    /// Duplicates a tab, opening a new tab with the same URL, privacy mode, and space.
    func duplicateTab(_ tab: BrowserTab) {
        let url = tab.currentURL ?? tab.webView?.url
        let newTab = BrowserTab(
            initialURL: url,
            privacyMode: tab.privacyMode,
            space: tab.space,
            kind: .web
        )
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.insert(newTab, at: idx + 1)
        } else {
            tabs.append(newTab)
        }
        selectedTabID = newTab.id
        if let url {
            loadInWebView(url)
        }
    }

    func moveTab(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < tabs.count,
              destination >= 0, destination <= tabs.count else { return }
        let moved = tabs.remove(at: source)
        let insertIndex = min(destination, tabs.count)
        tabs.insert(moved, at: insertIndex)
    }

    func forgetDomainInSidebar(_ host: String) {
        PrivacyManager.shared.forgetDomain(host)
    }
    // Session (called from ContentView onAppear / terminate)
    func restoreLastSession() {
        // Best-effort: if this is ever called at runtime (not just launch), pause any live
        // webViews on the outgoing tabs so we don't leak media. At normal launch the previous
        // process's webviews are already gone.
        for t in tabs where t.kind == .web { t.pauseAllMediaForClose() }

        // Preferred modern path (supports special tabs like passwords vault via kind, spaces, privacy, etc.)
        let snapshots = Persistence.loadTabSnapshots()
        if !snapshots.isEmpty {
            tabs = snapshots.map { BrowserTab(from: $0) }
            if tabs.isEmpty { tabs = [BrowserTab(kind: .web)] }
            selectedTabID = tabs.first?.id
            showingWebContent = tabs.first?.currentURL != nil
            return
        }

        // Special tabs (passwords vault, privacy power hub) are supported. The kind is restored
        // correctly by BrowserTab(from: TabSnapshot) and the main content switch in ContentView
        // will render the appropriate view (PasswordVaultTabView or PrivacyPowerHubTabView).

        // Legacy fallback
        guard let urls = UserDefaults.standard.stringArray(forKey: sessionKey), !urls.isEmpty else { return }
        tabs = urls.compactMap { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return BrowserTab(initialURL: url)
        }
        if tabs.isEmpty { tabs = [BrowserTab(kind: .web)] }
        selectedTabID = tabs.first?.id
        showingWebContent = tabs.first?.currentURL != nil
    }

    func saveCurrentSession() {
        // Private (ephemeral) tabs are never persisted — their URL is browsing data
        // the user expects to vanish when the tab closes.
        let snapshots = tabs.filter { $0.privacyMode == .standard }.map { TabSnapshot(from: $0) }
        Persistence.saveTabSnapshots(snapshots)
        // Tab URLs are sensitive browsing data — they live exclusively in the encrypted AppData path above.
        // The legacy UserDefaults URL array (sessionKey) is intentionally no longer written here.
    }
}
