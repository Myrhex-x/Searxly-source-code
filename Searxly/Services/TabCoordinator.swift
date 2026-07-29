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
        customTabCategories = data.customTabCategories

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

        // Media playback state from the `searxlyMedia` bridge → keep mid-playback tabs resident and
        // remember their position (so switching away from a playing YouTube tab and back doesn't reload
        // and restart it). object == nil so we receive every reporting webView; we map it to its tab.
        if !mediaStateObserverRegistered {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTabMediaStateChanged(_:)),
                name: .tabMediaStateChanged,
                object: nil
            )
            mediaStateObserverRegistered = true
        }
    }

    func saveAllData() {
        // Load current to preserve fields owned by other managers (vpnProfiles, tabSnapshots, appLock*,
        // hibernation config, etc.). We only override the fields this state directly owns.
        var data = Persistence.load()
        data.searxInstances = searxInstances
        data.history = history
        data.bookmarks = bookmarks
        data.customTabCategories = customTabCategories
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
        data.customTabCategories = customTabCategories
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

    /// Snap helper used by ⌘S / View ▸ Toggle Sidebar (rail ↔ expanded).
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
        guard PasswordVaultManager.shared.isAutofillActive else { return }
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

    /// Fills a two-factor code into the current page. 2FA prompts almost always live on a SECOND
    /// page shown after the password is accepted, which is why this is a separate action rather
    /// than part of `fillCurrentPageWithLogin`.
    ///
    /// Handles both shapes sites use: one field for the whole code, and the row of single-digit
    /// boxes that GitHub, Stripe and friends render (each box gets one digit, with input events
    /// dispatched per box so the page's own advance-to-next-field logic still runs).
    func fillCurrentPageWithTOTP(_ code: String) {
        guard PasswordVaultManager.shared.isAutofillActive else { return }
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
            }

            function isVisible(el) {
                if (el.disabled || el.readOnly) return false;
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
            }

            const all = Array.from(document.querySelectorAll('input')).filter(isVisible);

            // Split-digit inputs: several short numeric boxes, one character each.
            const boxes = all.filter(function(el) {
                const max = parseInt(el.getAttribute('maxlength') || '0', 10);
                const type = (el.type || 'text').toLowerCase();
                return max === 1 && (type === 'text' || type === 'tel' || type === 'number');
            });
            if (boxes.length >= code.length) {
                for (let i = 0; i < code.length; i++) { fillField(boxes[i], code[i]); }
                boxes[Math.min(code.length, boxes.length) - 1].dispatchEvent(new Event('blur', { bubbles: true }));
                return;
            }

            // Single field. `autocomplete="one-time-code"` is the standard signal and is checked
            // first; the name/id patterns are the fallback for sites that never adopted it.
            const scored = all.filter(function(el) {
                const type = (el.type || 'text').toLowerCase();
                return type === 'text' || type === 'tel' || type === 'number';
            });
            let target = scored.find(function(el) {
                return (el.getAttribute('autocomplete') || '').toLowerCase() === 'one-time-code';
            });
            if (!target) {
                target = scored.find(function(el) {
                    const hay = ((el.name || '') + ' ' + (el.id || '') + ' ' +
                                 (el.getAttribute('aria-label') || '') + ' ' +
                                 (el.placeholder || '')).toLowerCase();
                    return /otp|totp|2fa|mfa|one[-_ ]?time|auth(entication)?[-_ ]?code|verification[-_ ]?code|security[-_ ]?code/.test(hay);
                });
            }
            if (target) {
                fillField(target, code);
                target.dispatchEvent(new Event('blur', { bubbles: true }));
            }
        })();
        """
        activeWebView.callAsyncJavaScript(js,
                                          arguments: ["code": code],
                                          in: nil,
                                          in: .page,
                                          completionHandler: nil)
    }

    /// Fills only password field(s) on the current page. Used for "generate password directly here" flows
    /// on signup / create-account pages (no username required).
    func fillCurrentPageWithPassword(_ password: String) {
        guard PasswordVaultManager.shared.isSuggestPasswordsActive else { return }
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
        guard PasswordVaultManager.shared.isSuggestPasswordsActive else { return }

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
        guard PasswordVaultManager.shared.isAutofillActive else { return }

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

            guard PasswordVaultManager.shared.isOfferToSaveActive else { return }

            // Debounced offer notification (for save flows)
            let domain = self.currentWebDomain ?? ""
            if domain != self.lastOfferedSaveDomain {
                self.lastOfferedSaveDomain = domain
                NotificationCenter.default.post(name: Notification.Name("Searxly.OfferSaveLogin"), object: nil, userInfo: ["domain": domain])
            }
        }
    }
    /// Opens (or re-selects) a single full-page utility tab of the given non-web kind.
    /// One tab per kind: re-selects the existing one instead of duplicating it.
    func ensureAndSelectUtilityTab(_ kind: TabKind) {
        guard kind.isUtility else { return }

        if let existing = tabs.first(where: { $0.kind == kind }) {
            selectedTabID = existing.id
            showingWebContent = false
            return
        }

        let tab = BrowserTab(space: .personal, kind: kind)
        tabs.append(tab)
        selectedTabID = tab.id
        showingWebContent = false
        saveCurrentSession()
        // Utility tabs never hibernate or auto-cleanup (enforced by `kind == .web` guards elsewhere).
        #if DEBUG
        Log.web.info("[Utilities] Created and selected \(kind.rawValue) tab.")
        #endif
    }

    func ensureAndSelectPasswordsVaultTab() {
        guard PasswordVaultManager.isAvailable else { return }
        ensureAndSelectUtilityTab(.passwords)
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

    /// Opens a URL that arrived from outside the app — e.g. a link clicked in Mail/Slack/Messages when
    /// Searxly is the default browser (delivered via SearxlyApp's `.onOpenURL`). Opens in a fresh
    /// foreground tab. .onion links route to their own Tor tab via loadInWebView, so we don't pre-spawn
    /// an empty standard tab for them.
    func openExternalURL(_ url: URL) {
        if url.isFileURL {
            // "Open With Searxly" / double-click / drag-to-Dock of a local .html file. Route through the
            // local-file opener so the tab retains the sandbox grant and WebKit gets the right read access.
            openLocalFileURL(url)
        } else if url.isOnionService {
            loadInWebView(url)
        } else {
            newTab()
            loadInWebView(url)
        }
    }

    /// Opens a URL in a NEW BACKGROUND tab without leaving the current page (Safari ⌘-click behavior).
    /// The new tab loads itself via its own webView; selection is intentionally left unchanged.
    func openURLInBackgroundTab(_ url: URL) {
        let tab = BrowserTab(initialURL: url, kind: .web)
        // Insert after the current tab, like Safari, rather than at the very end.
        if let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }
        saveCurrentSession()
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
        // Tell the extension engine this tab is going away (chrome.tabs.onRemoved), while its webView
        // is still alive. Standard web tabs only — private/onion/utility tabs aren't exposed to Lane A.
        if #available(macOS 15.4, *), ExtensionFeatures.laneAEnabled,
           tab.privacyMode == .standard, tab.kind == .web, let webView = tab.webView {
            ExtensionManager.shared.tabClosed(webView)
        }

        // Pause media *before* we remove the tab from the array. When the last strong ref
        // to the BrowserTab disappears, its webView is released; we want the pause JS to
        // have run while the webView is still alive and attached to a WebContent process.
        if tab.kind == .web {
            tab.pauseAllMediaForClose()
        }

        // Release any security-scoped access this tab held for a local file/folder ("Open File…").
        tab.releaseSecurityScopedAccess()

        // Save a snapshot for "Reopen Closed Tab" (only web tabs with a URL are useful to restore).
        // Local files are excluded: their sandbox grant is gone once closed, so a restored file tab
        // couldn't read its file — offering it for reopen would just resurrect a broken page.
        if tab.kind == .web, let url = tab.currentURL, !url.absoluteString.isEmpty, !url.isFileURL {
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
            stopTorIfNoOnionTabsRemain()   // closing the last tab (e.g. an onion tab) → tear Tor down
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
            stopTorIfNoOnionTabsRemain()   // tear Tor down once the last onion tab is gone
            saveCurrentSession()   // Persist tab list right away — prevents stale sessions (e.g. speedtest) from reappearing after close
        }
    }

    /// Executes the full panic wipe after the user confirms (⌘⌥⇧⌫ → confirmation alert).
    /// Resets every piece of in-memory UI state that could re-persist or still display the old
    /// session, then hands off to PrivacyManager for the persisted-data / web-data / key wipe.
    func performPanicWipe() {
        // Pause media while the webviews are still alive, then drop every tab for one fresh tab.
        for tab in tabs where tab.kind == .web {
            tab.pauseAllMediaForClose()
        }
        tabs = [BrowserTab(kind: .web)]
        selectedTabID = tabs[0].id
        showingWebContent = false
        recentlyClosedSnapshots = []
        customTabCategories = []
        stopTorIfNoOnionTabsRemain()

        // In-memory caches (search results, history, bookmarks, suggestions).
        panicWipeRequested()

        // Persisted data, password vault, web storage, encryption key, local SearXNG stop.
        PrivacyManager.shared.panicWipe()
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
        newTab.categoryID = tab.categoryID   // the duplicate stays in the same sidebar category
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

    // MARK: - Custom sidebar categories

    /// Creates a new custom category (capped at `maxCustomCategories`). Trimmed + length-limited name.
    @discardableResult
    func addCategory(named name: String) -> TabCategory? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, customTabCategories.count < Self.maxCustomCategories else { return nil }
        let category = TabCategory(name: String(trimmed.prefix(24)))
        customTabCategories.append(category)
        saveAllData()
        return category
    }

    /// Renames an existing category. No-op if the name is blank or the category is unknown.
    func renameCategory(_ category: TabCategory, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = customTabCategories.firstIndex(where: { $0.id == category.id }) else { return }
        customTabCategories[idx].name = String(trimmed.prefix(24))
        saveAllData()
    }

    /// Deletes a category and returns any tabs assigned to it back to the default "TABS" group.
    func deleteCategory(_ category: TabCategory) {
        customTabCategories.removeAll { $0.id == category.id }
        for tab in tabs where tab.categoryID == category.id {
            tab.categoryID = nil
        }
        saveAllData()
        saveCurrentSession()
    }

    /// Assigns a tab to a category (nil = default "TABS"), appending it to the end of that group's
    /// run in the `tabs` array. Used by the right-click "Move to Category" menu and by dropping a tab
    /// onto a category header.
    func moveTab(_ tab: BrowserTab, toCategory categoryID: UUID?) {
        guard tab.kind == .web, tab.privacyMode != .onion else { return }
        tab.categoryID = categoryID
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let moved = tabs.remove(at: from)
        let insertAt: Int
        if let lastInGroup = tabs.lastIndex(where: { isCategorizable($0) && $0.categoryID == categoryID }) {
            insertAt = lastInGroup + 1
        } else {
            insertAt = tabs.count
        }
        tabs.insert(moved, at: min(max(0, insertAt), tabs.count))
        saveCurrentSession()
    }

    /// Reorders `tab` to sit immediately before `target`, adopting the target's category. Used when a
    /// tab is dropped directly onto another tab row in the sidebar.
    func moveTab(_ tab: BrowserTab, before target: BrowserTab) {
        guard tab.id != target.id else { return }
        // Keep pinned and unpinned worlds separate — dropping across that boundary is a no-op.
        guard tab.isPinned == target.isPinned else { return }
        if !tab.isPinned { tab.categoryID = target.categoryID }
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let moved = tabs.remove(at: from)
        let insertAt = tabs.firstIndex(where: { $0.id == target.id }) ?? tabs.count
        tabs.insert(moved, at: min(max(0, insertAt), tabs.count))
        saveCurrentSession()
    }

    /// A tab eligible for custom categories: a normal (non-onion) web tab.
    private func isCategorizable(_ tab: BrowserTab) -> Bool {
        tab.kind == .web && tab.privacyMode != .onion
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
        var snapshots = Persistence.loadTabSnapshots()
        // Extensions program is disabled for release — drop any Extensions tab persisted by an
        // earlier build so it can't resurface the hidden marketplace.
        if !ExtensionFeatures.programEnabled {
            snapshots.removeAll { $0.kind == .extensions }
        }
        // Password vault is Maximum-only — drop any vault tab persisted by an older base build (or a
        // Maximum session restored into the base app).
        if !PasswordVaultManager.isAvailable {
            snapshots.removeAll { $0.kind == .passwords }
        }
        if !snapshots.isEmpty {
            // Lazy restore: every web tab is created as a hibernated stub (no WKWebView, no page load).
            // Only the foreground tab is woken below, so cold start spins up exactly one WebContent
            // process and one network load instead of one per restored tab. Background stubs wake on
            // first selection via the onChange(of: selectedTabID) → didSelectTab → wakeUp path.
            tabs = snapshots.map { BrowserTab(from: $0, hibernated: true) }
            if tabs.isEmpty { tabs = [BrowserTab(kind: .web)] }
            wakeForegroundTabAfterRestore(tabs.first)
            return
        }

        // Special tabs (passwords vault, privacy power hub) are supported. The kind is restored
        // correctly by BrowserTab(from: TabSnapshot) and the main content switch in ContentView
        // will render the appropriate view (PasswordVaultTabView or PrivacyPowerHubTabView).

        // Legacy fallback
        guard let urls = UserDefaults.standard.stringArray(forKey: sessionKey), !urls.isEmpty else { return }
        tabs = urls.compactMap { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return BrowserTab(initialURL: url, hibernated: true)
        }
        if tabs.isEmpty { tabs = [BrowserTab(kind: .web)] }
        wakeForegroundTabAfterRestore(tabs.first)
    }

    /// Selects the foreground tab after a lazy restore and wakes it immediately, so `activeWebView`
    /// resolves to a real WKWebView (not the fallback) and the page begins loading right away.
    /// The remaining tabs stay hibernated stubs until the user selects them.
    private func wakeForegroundTabAfterRestore(_ foreground: BrowserTab?) {
        selectedTabID = foreground?.id

        if let foreground, foreground.kind == .web {
            // wakeUp() is a no-op if the tab isn't a stub; safe to call unconditionally for web tabs.
            foreground.wakeUp()
            TabHibernationManager.shared.didWakeTab(foreground)
        }

        // Canonical sync (drives showingWebContent / address bar off the selected tab's currentURL).
        syncWebStateFromSelectedTab()
        TabHibernationManager.shared.currentStats(among: tabs)
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
