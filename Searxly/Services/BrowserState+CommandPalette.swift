//
//  BrowserState+CommandPalette.swift
//  Searxly
//
//  Activation logic for the ⌘K command palette. Routes each result through the existing, well-tested
//  navigation paths (tab selection, loadInWebView, search, utility tabs) rather than duplicating them.
//

import Foundation

extension BrowserState {
    /// Runs the chosen palette result and dismisses the palette.
    func activatePaletteResult(_ action: PaletteAction) {
        switch action {
        case .switchToTab(let id):
            // Setting the selection drives onChange → didSelectTab → wakeUp (if hibernated) + sync.
            selectedTabID = id

        case .openURL(let url):
            openURLPreferringCurrentTab(url)

        case .search(let query):
            searchText = query
            performSearchOrLoadInWebKit()

        case .command(let cmd):
            runPaletteCommand(cmd)
        }

        showingCommandPalette = false
    }

    /// Opens a URL, loading in the current tab when it's a web tab; otherwise (a utility tab like
    /// Passwords/Bookmarks/Downloads) opens a fresh foreground web tab so we never hijack a non-web tab.
    /// Shared by the command palette and the bookmarks bar.
    func openURLPreferringCurrentTab(_ url: URL) {
        if selectedTab?.kind == .web {
            loadInWebView(url)
        } else {
            openExternalURL(url)
        }
    }

    private func runPaletteCommand(_ cmd: PaletteCommand) {
        switch cmd {
        case .newTab:        newTab()
        case .newPrivateTab: newPrivateTab()
        case .bookmarks:     ensureAndSelectUtilityTab(.bookmarks)
        case .downloads:     ensureAndSelectUtilityTab(.downloads)
        case .settings:      showingSettings = true
        case .importData:    showingImportData = true
        case .clearData:     showingClearData = true
        case .askAI:         openLocalAIChat()
        case .lock:          AppLockManager.shared.lock()
        }
    }
}
