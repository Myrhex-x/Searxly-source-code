//
//  ContentView+Sheets.swift
//  Searxly
//
//  Sheet presentations, overlays, and lifecycle/notification wiring for ContentView.
//

import SwiftUI
import AppKit
import WebKit

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
            .sheet(isPresented: $browserState.showingDownloads) { downloadsSheet }
            .sheet(isPresented: $browserState.showingBookmarks) { bookmarksSheet }
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
                    onContinue: { browserState.acknowledgeTorDisclosureAndContinue() },
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
                        },
                        onAskAI: {
                            browserState.showingReaderSheet = false
                            browserState.isReaderMode = false
                            browserState.openLocalAIChat()
                        },
                        onTalkToSearxly: { summary, title in
                            // Continue the reader summary in the full chat. Only the model's summary +
                            // the page title cross over — never the raw (untrusted) page text.
                            browserState.showingReaderSheet = false
                            browserState.isReaderMode = false
                            browserState.pendingAIChatSeed = AIChatSeed(
                                selection: title.isEmpty ? "this page" : title,
                                action: .summarizePage,
                                priorAnswer: summary
                            )
                            browserState.openLocalAIChat()
                        }
                    )
                }
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
                // Onion tabs aren't restored, so a Tor process alive at launch is stale — reap it.
                Task { await TorManager.shared.cleanupStaleAtLaunch() }
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
            .onReceive(NotificationCenter.default.publisher(for: .onionLocationDetected)) { note in
                guard let onionStr = note.userInfo?["onion"] as? String,
                      let onion = URL(string: onionStr),
                      let host = note.userInfo?["host"] as? String else { return }
                browserState.noteOnionLocation(onion, forPageHost: host)
            }
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
                guard PasswordVaultManager.shared.autofillEnabled else { return }
                if let info = notification.userInfo as? [String: String],
                   let user = info["username"],
                   let pass = info["password"] {
                    browserState.fillCurrentPageWithLogin(username: user, password: pass)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Searxly.OfferSaveLogin"))) { notification in
                guard passwordVault.offerToSaveEnabled else { return }
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
            .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
                browserState.showingKeyboardShortcuts = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToSearch)) { _ in
                browserState.settingsInitialCategory = .search
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsToVPN)) { _ in
                browserState.settingsInitialCategory = .vpn
                browserState.showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Searxly.LocalAIClearRequested"))) { _ in
                browserState.clearAIState()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Searxly.OpenLocalAIChatRequested"))) { _ in
                browserState.openLocalAIChat()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                NotificationManager.shared.isBrowserActive = browserState.showingWebContent
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
            }
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
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var keyboardShortcutsSheet: some View {
        KeyboardShortcutsView(isPresented: $browserState.showingKeyboardShortcuts)
    }

    /// The wired Local AI Chat content is now extracted to its own file (the closures for private search,
    /// openWebsite, and RAG are implemented there).
    /// See Views/Features/LocalAI/LocalAIChatView.swift
    var localAIChatView: some View {
        LocalAIChatView(browserState: browserState)
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

}
