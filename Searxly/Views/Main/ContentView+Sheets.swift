//
//  ContentView+Sheets.swift
//  Searxly
//
//  Sheet presentations, overlays, and lifecycle/notification wiring for ContentView.
//

import SwiftUI
import AppKit
import WebKit
import Translation

/// Onion/Tor notification wiring, extracted into its own modifier so it type-checks independently of
/// ContentView's long sheet/modifier chain (which otherwise blows the compiler's complexity budget).
private struct OnionTabNotifications: ViewModifier {
    let browserState: BrowserState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .onionLocationDetected)) { note in
                guard let onionStr = note.userInfo?["onion"] as? String,
                      let onion = URL(string: onionStr),
                      let host = note.userInfo?["host"] as? String else { return }
                browserState.noteOnionLocation(onion, forPageHost: host)
            }
            .onReceive(NotificationCenter.default.publisher(for: .onionUnreachable)) { note in
                if let host = note.userInfo?["host"] as? String {
                    browserState.markOnionUnreachable(host)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .torDisabled)) { _ in
                browserState.handleTorDisabled()
            }
    }
}

/// Menu-bar / global keyboard command notifications (Help ▸ Keyboard Shortcuts, ⌘K command palette,
/// and the "open Settings to X" deep links). Extracted into its own modifier so it type-checks
/// independently of ContentView's long sheet/modifier chain (same reason as OnionTabNotifications).
private struct MenuCommandNotifications: ViewModifier {
    // @Bindable (not let) because the panic-wipe confirmation alert needs a Binding into
    // the @Observable BrowserState.
    @Bindable var browserState: BrowserState
    /// ⌘S / View ▸ Toggle Sidebar. Owned by ContentView so auto-hide pin state can live next to
    /// the hover-reveal flags (both are view chrome, not BrowserState).
    let onToggleSidebar: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
                browserState.showingKeyboardShortcuts = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .panicWipeRequested)) { _ in
                browserState.showingPanicWipeConfirm = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .newIdentityRequested)) { _ in
                browserState.newIdentity()
            }
            .alert("Panic Wipe — Clear Everything?", isPresented: $browserState.showingPanicWipeConfirm) {
                Button("Wipe Everything", role: .destructive) {
                    browserState.performPanicWipe()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Immediately deletes history, bookmarks, open tabs, saved logins, cookies and site data, VPN profiles, and AI chat context on this Mac. The wallet is not touched. This cannot be undone.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { _ in
                // ⌘K toggles the palette so a second press closes it.
                browserState.showingCommandPalette.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .findInPageRequested)) { _ in
                // ⌘F (and the ☰ menu's Find on Page) — show the find bar on the current page.
                browserState.showFindInPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadPageRequested)) { _ in
                // ⌘R — reload the current web page (menu command so it works over focused WKWebView).
                browserState.reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openLocalFileRequested)) { _ in
                // ⌘O (File ▸ Open File…) — pick a local HTML file / web-project folder to view.
                browserState.openLocalFile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerModeRequested)) { _ in
                // ⌘⇧R (and the ☰ menu's Reader View) — toggle the distraction-free reader.
                browserState.toggleReaderModeAction()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequested)) { _ in
                // ⌘S (and View ▸ Toggle Sidebar) — auto-hide: pin/unpin the overlay tab panel;
                // classic: collapse/expand the left tab rail. Same spring as the chevron.
                onToggleSidebar()
            }
            // On-device page translation (☰ → Translate Page). The session lives on this modifier;
            // PageTranslator sets `configuration` to start a run, and the framework presents its own
            // language-pack download UI from here when a pair needs assets.
            .translationTask(PageTranslator.shared.configuration) { session in
                await PageTranslator.shared.run(session)
            }
            // Settings-navigation + import commands are grouped into their own modifier so this chain
            // stays short enough for the SwiftUI type-checker (adding one more .onReceive here tips it
            // past its budget: "unable to type-check this expression in reasonable time").
            .modifier(SettingsNavigationCommands(browserState: browserState))
    }
}

/// The "open Settings to category X" and "import data" menu commands, split out of
/// MenuCommandNotifications to keep each view-modifier chain within the SwiftUI type-checker's budget.
private struct SettingsNavigationCommands: ViewModifier {
    let browserState: BrowserState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSearch)) { _ in
                browserState.settingsInitialCategory = .search
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToVPN)) { _ in
                browserState.settingsInitialCategory = .vpn
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToPrivacy)) { _ in
                browserState.settingsInitialCategory = .privacy
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToAgenticTools)) { _ in
                browserState.settingsInitialCategory = .agenticTools
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .importDataRequested)) { _ in
                // If Settings is open, dismiss it first so we don't stack sheet-over-sheet.
                if browserState.showingSettings {
                    browserState.showingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        browserState.showingImportData = true
                    }
                } else {
                    browserState.showingImportData = true
                }
            }
    }
}

/// File ▸ New Tab (⌘T) / New Private Tab (⌘⇧T). The handlers live on ContentView because opening the
/// tab is only half the job — the caret has to land in the address bar, and that focus state is the
/// view's. Its own modifier so ContentView's notification chain stays inside the type-checker's budget.
private struct TabCommandNotifications: ViewModifier {
    let onNewTab: () -> Void
    let onNewPrivateTab: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .newTabRequested)) { _ in
                onNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newPrivateTabRequested)) { _ in
                onNewPrivateTab()
            }
    }
}

/// Tab lifecycle reclaim: the inactivity sweep and OS memory-pressure responses. ContentView owns the
/// tab list, so the TabHibernationManager (which only knows the policy) posts these and we act here.
/// Extracted as a modifier so it type-checks independently of ContentView's long modifier chain.
private struct TabLifecycleNotifications: ViewModifier {
    let browserState: BrowserState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .tabHibernationAutoSweepDue)) { _ in
                TabHibernationManager.shared.performInactivityBasedHibernation(
                    currentTab: browserState.selectedTab,
                    among: browserState.tabs
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .tabHibernationMemoryPressureDue)) { _ in
                // Under memory pressure, hibernate every background tab (they reload on selection).
                TabHibernationManager.shared.hibernateAllBackgroundTabs(
                    except: browserState.selectedTab,
                    among: browserState.tabs
                )
            }
    }
}

/// Lane A (WebExtensions) tab-API bridge: an extension asked to activate / close / create a tab, and
/// tab-selection changes fire chrome.tabs.onActivated. Bundled as a modifier so the main view body
/// stays under the type-checker's complexity ceiling.
private struct LaneAExtensionNotifications: ViewModifier {
    let browserState: BrowserState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .laneASelectTabByWebView)) { note in
                guard let wv = note.object as? WKWebView,
                      let tab = browserState.tabs.first(where: { $0.webView === wv }) else { return }
                browserState.selectedTabID = tab.id
            }
            .onReceive(NotificationCenter.default.publisher(for: .laneACloseTabByWebView)) { note in
                guard let wv = note.object as? WKWebView,
                      let tab = browserState.tabs.first(where: { $0.webView === wv }) else { return }
                browserState.closeTab(tab)
            }
            .onReceive(NotificationCenter.default.publisher(for: .laneANewTabRequested)) { _ in
                guard ExtensionFeatures.programEnabled else { return }
                browserState.newTab()
            }
            .onChange(of: browserState.selectedTabID) { _, _ in
                if #available(macOS 15.4, *), ExtensionFeatures.laneAEnabled {
                    let tab = browserState.selectedTab
                    let standard = tab?.privacyMode == .standard && !(tab?.kind.isUtility ?? true)
                    ExtensionManager.shared.setActiveTab(standard ? tab?.webView : nil)
                }
            }
    }
}

extension ContentView {
    var baseWithSheets: some View {
        sidebarLayout
            .frame(minWidth: 900, minHeight: 600)
            .background(AdaptiveChrome.appCanvas(resolvedColorScheme, glassEnabled: glassEnabled))
            .preferredColorScheme(resolvedColorScheme)
            .onAppear { refreshSystemColorScheme() }
            .onChange(of: appearanceModeRaw) { _, _ in
                if (AppearanceMode(rawValue: appearanceModeRaw) ?? .system) == .system {
                    refreshSystemColorScheme()
                }
            }
            .onReceive(AppearanceResolver.systemAppearanceDidChange) { _ in
                refreshSystemColorScheme()
            }
            .overlay(DAppApprovalHost())
            .sheet(isPresented: $browserState.showingSettings) { settingsSheet }
            // Downloads / Bookmarks & History / Full History now open as full-page Utility tabs
            // (grouped under the sidebar "Utilities" category) instead of sheets/overlays. The existing
            // buttons still flip these flags; we intercept them here, open the matching utility tab,
            // and reset the flag.
            .onChange(of: browserState.showingDownloads) { _, show in
                if show {
                    browserState.showingDownloads = false
                    browserState.ensureAndSelectUtilityTab(.downloads)
                }
            }
            .onChange(of: browserState.showingBookmarks) { _, show in
                if show {
                    browserState.showingBookmarks = false
                    browserState.ensureAndSelectUtilityTab(.bookmarks)
                }
            }
            .onChange(of: browserState.showingFullHistory) { _, show in
                if show {
                    browserState.showingFullHistory = false
                    browserState.ensureAndSelectUtilityTab(.bookmarks)
                }
            }
            .sheet(isPresented: $browserState.showingKeyboardShortcuts) { keyboardShortcutsSheet }
            .sheet(isPresented: $showingWebSaveLogin) {
                SaveLoginSheet(
                    domain: webSaveDomain,
                    initialUsername: webSaveUsername,
                    initialPassword: webSavePassword,
                    onCancel: { showingWebSaveLogin = false },
                    onSaved: { showingWebSaveLogin = false }
                )
            }
            .sheet(isPresented: $browserState.showTorDisclosure) {
                TorDisclosureSheet(
                    onContinue: { browserState.enableTorAndOpenPending() },
                    onCancel: { browserState.cancelTorDisclosure() }
                )
            }
            .sheet(isPresented: $browserState.showingClearData) {
                ClearBrowsingDataView()
            }
            .sheet(isPresented: $browserState.showingReaderSheet) {
                if !browserState.readerHTML.isEmpty {
                    ReaderView(
                        title: browserState.readerTitle,
                        html: browserState.readerHTML,
                        onDismiss: {
                            browserState.showingReaderSheet = false
                            browserState.isReaderMode = false
                            browserState.readerHTML = ""
                            browserState.readerTitle = ""
                        }
                    )
                }
            }
            .sheet(isPresented: $browserState.showingImportData) {
                ImportDataView(
                    browserState: browserState,
                    glassEnabled: glassEnabled,
                    onClose: { browserState.showingImportData = false }
                )
            }
            // Local AI chat is now a custom centered overlay (fluid "pops from middle" animation)
            // instead of a native sheet for better in-browser feel. See localAIChatOverlay below.
    }

    /// Lifecycle, persistence, keyboard, and notification wiring.
    /// Separate property to keep individual expressions tractable for the compiler.
    var baseWithSheetsAndEvents: some View {
        baseWithSheets
            .onAppear {
                _ = Persistence.load()
                // Onion tabs aren't restored, so a leftover Tor at launch is normally stale — reap it.
                // EXCEPTION: when we launch already in Maximum + Tor, PrivacyGate brings Tor up at launch
                // and OWNS its lifecycle. Reaping here races that auto-start and kills the freshly-spawned
                // process — start() then sits in its bootstrap wait holding `isBusy`, so the pill's
                // "Start Tor" looks dead (guarded out by isBusy) and protection never comes up. In that
                // case leave Tor to the gate, which adopts a still-running instance or starts a fresh one.
                // (This is the "clicking Start Tor does nothing" bug — hit by any build relaunched into
                // persisted Maximum+Tor, and always by Searxly Maximum since it's Maximum+Tor by design.)
                let gateOwnsTor = PrivacyManager.shared.appPrivacyMode == .maximum
                    && PrivacyManager.shared.maxProtection == .tor
                if !gateOwnsTor {
                    Task { await TorManager.shared.cleanupStaleAtLaunch() }
                }
                guard !encryptionRecoveryManager.isRecoveryRequired else { return }
                if appLockManager.isAppLockEnabled && !appLockManager.isUnlocked {
                    return
                }
                performInitialLaunchLoadIfNeeded()
            }
            .onChange(of: appLockManager.isUnlocked) { _, isUnlocked in
                guard !encryptionRecoveryManager.isRecoveryRequired else { return }
                if isUnlocked {
                    performInitialLaunchLoadIfNeeded()
                }
            }
            .onChange(of: encryptionRecoveryManager.isRecoveryRequired) { _, isRequired in
                if !isRequired {
                    hasCompletedInitialLaunchLoad = false
                    performInitialLaunchLoadIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Single combined save — tabs + all state in one Persistence.save() call
                // so the keychain (encryption key) is accessed only once on quit.
                browserState.saveAllDataIncludingSession()
                browserState.saveSidebarPreferences()
                AppLockManager.shared.prepareForTermination()
                // Best-effort: stop Tor on quit so no orphaned tor lingers (launch cleanup reaps any that survive).
                Task { await TorManager.shared.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showPasswordsVaultTabRequested)) { _ in
                browserState.ensureAndSelectPasswordsVaultTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showExtensionsTabRequested)) { _ in
                // The full-page Extensions marketplace was removed — management now lives in
                // Settings → Extensions (installs come from the Chrome Web Store). Every legacy entry
                // point that posted this now opens that settings pane instead.
                guard ExtensionFeatures.programEnabled else { return }
                browserState.settingsInitialCategory = .extensions
                browserState.showingSettings = true
            }
            .modifier(LaneAExtensionNotifications(browserState: browserState))
            .modifier(OnionTabNotifications(browserState: browserState))
            .modifier(TabLifecycleNotifications(browserState: browserState))
            .modifier(TabCommandNotifications(
                onNewTab: { newTab() },
                onNewPrivateTab: { newPrivateTab() }
            ))
            .onReceive(NotificationCenter.default.publisher(for: .dataRestoredFromBackup)) { _ in
                hasCompletedInitialLaunchLoad = false
                browserState.handleDataRestored()
                performInitialLaunchLoadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptionRecoverySucceeded)) { _ in
                hasCompletedInitialLaunchLoad = false
                browserState.handleDataRestored()
                performInitialLaunchLoadIfNeeded()
            }
            // (showPowerHubTabRequested and showHoldersCommunityTabRequested receivers removed with the power hub + holders community tabs.)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Searxly.FillLoginRequested"))) { notification in
                guard PasswordVaultManager.shared.isAutofillActive else { return }
                if let info = notification.userInfo as? [String: String],
                   let user = info["username"],
                   let pass = info["password"] {
                    browserState.fillCurrentPageWithLogin(username: user, password: pass)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Searxly.OfferSaveLogin"))) { notification in
                guard passwordVault.isOfferToSaveActive else { return }
                if let domain = (notification.userInfo as? [String: String])?["domain"], !domain.isEmpty {
                    webSaveDomain = domain
                    browserState.extractCredentialsFromCurrentPage { username, password in
                        webSaveUsername = username
                        webSavePassword = password
                        if !username.isEmpty || !password.isEmpty {
                            showingWebSaveLogin = true
                        }
                    }
                }
            }
            .onChange(of: browserState.searxInstances) { _, _ in
                Persistence.saveInstances(browserState.searxInstances)
            }
            .onChange(of: browserState.history) { _, _ in
                Persistence.saveHistory(browserState.history)
            }
            .onChange(of: browserState.bookmarks) { _, _ in
                Persistence.saveBookmarks(browserState.bookmarks)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openExternalURL)) { note in
                if let url = note.object as? URL {
                    browserState.openExternalURL(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openURLInNewTab)) { note in
                if let url = note.object as? URL {
                    // Explicit modifier-clicks always win: ⌘-click = background (true), ⌘⇧-click =
                    // foreground (false). Automatic opens (target="_blank", window.open, "Open Link in New
                    // Tab") carry no flag → follow the "Open new tabs in the background" preference.
                    let explicitBackground = note.userInfo?["background"] as? Bool
                    let background = explicitBackground
                        ?? UserDefaults.standard.bool(forKey: NavigationCoordinatorKeys.openNewTabsInBackground)
                    // Onion links need a Tor-routed tab (openExternalURL handles that) — never a plain
                    // background web tab, which would try to load .onion directly and fail.
                    if background && !url.isOnionService {
                        browserState.openURLInBackgroundTab(url)
                    } else {
                        browserState.openExternalURL(url)
                    }
                }
            }
            .modifier(MenuCommandNotifications(
                browserState: browserState,
                onToggleSidebar: { handleToggleSidebar() }
            ))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                NotificationManager.shared.isBrowserActive = browserState.showingWebContent
                // Resume the (battery-saving) idle hibernation timer paused on background.
                TabHibernationManager.shared.resumeAutoSweep()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchContentSafetyDidChange)) { _ in
                browserState.refreshSearchAfterContentSafetyChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                // Flush current tab session when the app loses focus / goes to background.
                // willTerminate is not reliable enough on macOS (force quit, crashes, sudden termination, etc.).
                // Saving here + on structural changes (closeTab, newTab, loadInWebView) makes "I closed speedtest but it came back"
                // and similar stale session problems much less likely.
                browserState.saveCurrentSession()
                // Pause the 5s idle hibernation timer while backgrounded (battery). Memory pressure still
                // reclaims if needed; the sweep resumes (and catches up) on becoming active.
                TabHibernationManager.shared.suspendAutoSweep()
            }
            .onChange(of: browserState.selectedTabID) { _, newID in
                browserState.onionLocationOffer = nil   // page changed — drop any stale onion offer
                guard let newID = newID,
                      let tab = browserState.tabs.first(where: { $0.id == newID }) else { return }
                TabHibernationManager.shared.didSelectTab(tab, amongAllTabs: browserState.tabs)
                browserState.syncWebStateFromSelectedTab()

                // Light post-selection stabilization nudge (especially valuable after hibernation wake).
                // The LayoutFixer script (factory), WebViewContainer.layout(), and Coordinator didFinish
                // are the primary mechanisms; this is an extra cheap poke for the just-attached case.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if let wv = tab.webView {
                        wv.evaluateJavaScript("""
                        (function(){ try { window.dispatchEvent(new Event('resize')); void document.documentElement.offsetWidth; } catch(e){} })();
                        """, completionHandler: nil)
                    }
                }
            }
    }

    // Extracted sheet contents and overlay to keep any single expression small enough for the SwiftUI type checker.
    var settingsSheet: some View {
        SettingsView(
            reduceLiquidGlass: $reduceLiquidGlass,
            searxInstances: $browserState.searxInstances,
            currentInstanceID: $browserState.currentInstanceID,
            knowledgePanelEnabled: Binding(
                get: { browserState.knowledgePanelEnabled },
                set: { browserState.setKnowledgePanelEnabled($0) }
            ),
            showingClearData: $browserState.showingClearData,
            initialCategory: browserState.settingsInitialCategory
        )
    }

    var downloadsSheet: some View {
        DownloadsSheetView(isPresented: $browserState.showingDownloads)
    }

    var bookmarksSheet: some View {
        BookmarksHistoryView(
            bookmarks: $browserState.bookmarks,
            history: $browserState.history,
            searchText: $browserState.searchText,
            showingBookmarks: $browserState.showingBookmarks,
            loadInWebView: browserState.loadInWebView,
            glassEnabled: glassEnabled,
            onRequestFullHistory: {
                browserState.showingBookmarks = false
                browserState.showingFullHistory = true
            },
            onOpenImport: { browserState.showingImportData = true }
        )
        .presentationBackground {
            if glassEnabled {
                Rectangle().fill(.regularMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    var fullHistoryContent: some View {
        BookmarksHistoryView(
            bookmarks: $browserState.bookmarks,
            history: $browserState.history,
            searchText: $browserState.searchText,
            showingBookmarks: .constant(false),
            loadInWebView: { url in
                browserState.loadInWebView(url)
                browserState.showingFullHistory = false
            },
            isFullPage: true,
            glassEnabled: glassEnabled,
            onCloseFullPage: {
                browserState.showingFullHistory = false
            },
            onOpenImport: { browserState.showingImportData = true }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Full-page content for an internal utility tab (Passwords, Bookmarks & History, Downloads).
    /// Each renders the existing feature view full-page; closing it closes the tab.
    @ViewBuilder
    func utilityTabContent(for tab: BrowserTab) -> some View {
        switch tab.kind {
        case .passwords:
            // Vault is Maximum-only; base builds never open this kind (session restore strips it).
            if PasswordVaultManager.isAvailable {
                PasswordVaultTabView(
                    tab: tab,
                    glassEnabled: glassEnabled,
                    toolbarMaterial: toolbarMaterial,
                    onFillLogin: { domain, username, password in
                        browserState.fillLoginForDomain(domain: domain, username: username, password: password)
                    },
                    onFillTOTP: { code in
                        browserState.fillCurrentPageWithTOTP(code)
                    },
                    onOpenSite: { domain in
                        if let url = URL(string: "https://\(domain)") {
                            browserState.loadInWebView(url)
                        }
                    }
                )
            } else {
                Color.clear
            }
        case .bookmarks:
            BookmarksHistoryView(
                bookmarks: $browserState.bookmarks,
                history: $browserState.history,
                searchText: $browserState.searchText,
                showingBookmarks: .constant(false),
                loadInWebView: { browserState.loadInWebView($0) },
                isFullPage: true,
                glassEnabled: glassEnabled,
                onCloseFullPage: { browserState.closeTab(tab) },
                onOpenImport: { browserState.showingImportData = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .downloads:
            DownloadsSheetView(isPresented: Binding(
                get: { true },
                set: { if !$0 { browserState.closeTab(tab) } }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .extensions:
            // The full-page Extensions marketplace was removed. This tab kind is no longer created;
            // any stray/restored one redirects to Settings → Extensions and closes itself.
            Color.clear.onAppear {
                browserState.closeTab(tab)
                if ExtensionFeatures.programEnabled {
                    browserState.settingsInitialCategory = .extensions
                    browserState.showingSettings = true
                }
            }
        case .web:
            EmptyView()
        }
    }

    var keyboardShortcutsSheet: some View {
        KeyboardShortcutsView(isPresented: $browserState.showingKeyboardShortcuts)
    }

    @ViewBuilder
    var onboardingOverlay: some View {
        if !hasCompletedOnboarding {
            OnboardingView(
                hasCompletedOnboarding: $hasCompletedOnboarding,
                searxInstances: $browserState.searxInstances,
                currentInstanceID: $browserState.currentInstanceID,
                glassEnabled: glassEnabled,
                toolbarMaterial: toolbarMaterial
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .opacity
            ))
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: hasCompletedOnboarding)
        }
    }

    /// Full-screen App Lock overlay. Appears when the feature is enabled, the app has not yet
    /// been authenticated this launch (or after manual/inactivity lock), and onboarding is complete.
    @ViewBuilder
    var appLockOverlay: some View {
        if !encryptionRecoveryManager.isRecoveryRequired,
           appLockManager.isAppLockEnabled,
           !appLockManager.isUnlocked,
           hasCompletedOnboarding {
            AppLockView(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)
                .transition(.opacity)
                .zIndex(999)
        }
    }

    /// Blocks the entire app when encrypted local data cannot be decrypted.
    @ViewBuilder
    var encryptionRecoveryOverlay: some View {
        if encryptionRecoveryManager.isRecoveryRequired {
            EncryptionRecoveryView(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial)
                .transition(.opacity)
                .zIndex(1000)
        }
    }

    /// Blocks the entire app until Searxly Maximum is activated. Deliberately the OUTERMOST gate — an
    /// unlicensed copy shows nothing else: not the browser, not onboarding, not even the App Lock, since
    /// there is nothing yet to protect. Never appears in the base app (`requiresActivation` is a
    /// constant false there, so this is dead-stripped).
    ///
    /// Reads `LicenseManager.shared` directly (not via `@State`) so Observation registers the gate
    /// field. A full-bleed black background is drawn even before the view's own content appears, so a
    /// slow first paint can never flash the browser underneath.
    @ViewBuilder
    var maximumActivationOverlay: some View {
        if LicenseManager.shared.requiresActivation {
            ZStack {
                Color.black.ignoresSafeArea()
                MaximumActivationView(glassEnabled: glassEnabled)
            }
            .transition(.opacity)
            .zIndex(1001)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

}
