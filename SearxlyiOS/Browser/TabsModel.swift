//
//  TabsModel.swift
//  SearxlyiOS
//
//  Owns the open tabs and which one is active. Each tab is a BrowserModel (its own WKWebView).
//  Tabs come in two kinds — normal and Private (session-ephemeral data store, no history) — and
//  closed normal tabs are remembered for "Reopen Closed Tab" (private ones never are).
//

import SwiftUI
import UIKit
import WebKit
import Observation

/// A closed tab the user can restore (normal tabs only — private tabs leave no trace).
struct ClosedTab: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
}

@MainActor
@Observable
final class TabsModel {
    private(set) var tabs: [BrowserModel]
    var activeID: UUID

    /// Most-recent-first, capped. Never contains private tabs.
    private(set) var recentlyClosed: [ClosedTab] = []
    private static let recentlyClosedCap = 10

    /// Whether private tabs have been biometrically revealed this foreground session.
    private(set) var privateTabsRevealed = false

    /// Private tabs are hidden behind Face ID: setting on, private tabs exist, not yet revealed.
    var privateTabsLocked: Bool {
        ShieldSettings.shared.lockPrivateTabs && hasPrivateTabs && !privateTabsRevealed
    }

    @discardableResult
    func revealPrivateTabs() async -> Bool {
        guard privateTabsLocked else { return true }
        let ok = await AppLockManager.confirm(reason: "Reveal your private tabs")
        if ok { privateTabsRevealed = true }
        return ok
    }

    /// On-disk shape of the saved session (encrypted, same store as the library).
    private struct SavedSession: Codable {
        struct SavedTab: Codable {
            let url: String
            let title: String
        }
        var tabs: [SavedTab]
        var activeIndex: Int
    }

    private static let sessionFile = SecureLibraryStorage.fileURL(name: "Tabs.enc")
    private static let restoreCap = 10

    init() {
        // Restore last session's tabs (web pages only, never private, capped) — Safari behavior.
        let saved: SavedSession? = {
            guard ShieldSettings.shared.restoreTabs, !ShieldSettings.shared.clearDataOnExit else { return nil }
            return SecureLibraryStorage.load(SavedSession.self, from: Self.sessionFile)
        }()

        if let saved, !saved.tabs.isEmpty {
            var restored: [(tab: BrowserModel, url: URL)] = []
            for entry in saved.tabs.prefix(Self.restoreCap) {
                guard let url = URL(string: entry.url) else { continue }
                restored.append((BrowserModel(), url))
            }
            if restored.isEmpty {
                let first = BrowserModel()
                tabs = [first]
                activeID = first.id
            } else {
                let idx = min(max(saved.activeIndex, 0), restored.count - 1)
                // Only the active tab loads at launch; the rest park and load on first activation —
                // a huge launch win (no more N concurrent page loads + N script injections for N tabs).
                for (i, entry) in restored.enumerated() {
                    if i == idx { entry.tab.load(entry.url) } else { entry.tab.parkForRestore(entry.url) }
                }
                tabs = restored.map(\.tab)
                activeID = restored[idx].tab.id
            }
        } else {
            let first = BrowserModel()
            tabs = [first]
            activeID = first.id
        }
        for tab in tabs { wire(tab) }

        // Persist when the app heads to background — the one reliable "session ended" signal.
        // Also re-lock private tabs so they need Face ID again on return, and — critically for
        // battery — suspend all media so a page that's playing (or autoplaying) audio/video can't
        // keep WebKit's media session, and therefore the whole app, awake in the background.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistSession()
                self?.privateTabsRevealed = false
                self?.setMediaPlaybackSuspended(true)
            }
        }

        // Coming back to the foreground: lift the media suspension so the user can play again.
        // Nothing auto-resumes — media we paused stays paused until tapped.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setMediaPlaybackSuspended(false) }
        }

        // Memory pressure: hibernate every background tab (about:blank placeholder + snapshot)
        // instead of letting the OS jetsam the whole app for holding N live web views.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hibernateBackgroundTabs() }
        }
    }

    private func hibernateBackgroundTabs() {
        for tab in tabs where tab.id != activeID { tab.hibernate() }
    }

    /// Suspends (or resumes) HTML5 media on every live tab as the app leaves/enters the foreground.
    /// This is the fix for "backgrounded Searxly heats the phone and drains the battery all day":
    /// a page playing or autoplaying audio/video keeps WebKit's media session — and therefore the
    /// whole app — from being suspended by iOS, so it keeps running (decoding media, firing the
    /// page's timers) indefinitely in the background. Suspending media releases that hold; iOS then
    /// suspends the app, which also stops every background task, timer, and animation. There is no
    /// audio background mode, so nothing else keeps us awake once media is quiet.
    private func setMediaPlaybackSuspended(_ suspended: Bool) {
        for tab in tabs {
            if suspended { tab.webView.pauseAllMediaPlayback(completionHandler: nil) }
            tab.webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
        }
    }

    /// Saves open web tabs (never private, never transient home/results states).
    func persistSession() {
        guard ShieldSettings.shared.restoreTabs, !ShieldSettings.shared.clearDataOnExit else {
            SecureLibraryStorage.erase(url: Self.sessionFile)
            return
        }
        var entries: [SavedSession.SavedTab] = []
        var activeIndex = 0
        for tab in tabs where !tab.isPrivate {
            // sessionURL survives hibernation (about:blank placeholder would otherwise drop the tab).
            guard let url = tab.sessionURL else { continue }
            if tab.id == activeID { activeIndex = entries.count }
            entries.append(SavedSession.SavedTab(url: url.absoluteString, title: tab.pageTitle))
        }
        if entries.isEmpty {
            SecureLibraryStorage.erase(url: Self.sessionFile)
        } else {
            SecureLibraryStorage.save(SavedSession(tabs: entries, activeIndex: activeIndex), to: Self.sessionFile)
        }
    }

    var active: BrowserModel {
        tabs.first { $0.id == activeID } ?? tabs[0]
    }

    var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    var hasPrivateTabs: Bool { tabs.contains { $0.isPrivate } }

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false) -> BrowserModel {
        let tab = BrowserModel(isPrivate: isPrivate)
        wire(tab)
        tabs.append(tab)
        activeID = tab.id
        if let url { tab.load(url) }
        return tab
    }

    /// Opens a tab in the background — appended and loaded, but the active tab stays put
    /// (queue links while reading, Safari-style).
    func newTabInBackground(url: URL, isPrivate: Bool = false) {
        let tab = BrowserModel(isPrivate: isPrivate)
        wire(tab)
        tab.load(url)
        tabs.append(tab)
    }

    func activate(_ tab: BrowserModel) {
        guard tab.id != activeID else { return }
        active.captureSnapshot() // keep the outgoing tab's grid card fresh
        activeID = tab.id
        tab.reviveIfNeeded()
    }

    /// Swipe-to-switch (Safari-style horizontal swipe on the bottom bar).
    func switchToPrevious() {
        let i = activeIndex
        guard i > 0 else { return }
        active.captureSnapshot()
        activeID = tabs[i - 1].id
        active.reviveIfNeeded()
        Haptics.tick()
    }

    func switchToNext() {
        let i = activeIndex
        guard i < tabs.count - 1 else { return }
        active.captureSnapshot()
        activeID = tabs[i + 1].id
        active.reviveIfNeeded()
        Haptics.tick()
    }

    /// Route a tab's pop-up / target=_blank requests into a new tab (matching privacy: pop-ups
    /// from a private tab stay private), and link-menu "Open in Private Tab" into a private one.
    private func wire(_ tab: BrowserModel) {
        tab.onOpenInNewTab = { [weak self, weak tab] url in
            self?.newTab(url: url, isPrivate: tab?.isPrivate ?? false)
        }
        tab.onOpenInNewTabBackground = { [weak self, weak tab] url in
            self?.newTabInBackground(url: url, isPrivate: tab?.isPrivate ?? false)
        }
        tab.onOpenInNewPrivateTab = { [weak self] url in
            self?.newTab(url: url, isPrivate: true)
        }
    }

    func close(_ tab: BrowserModel) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        rememberClosed(tab)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            newTab()
        } else if tab.id == activeID {
            // Activate the neighbour that slides into this slot.
            activeID = tabs[min(idx, tabs.count - 1)].id
        }
    }

    func closeOthers(keeping tab: BrowserModel) {
        for other in tabs where other.id != tab.id { rememberClosed(other) }
        tabs.removeAll { $0.id != tab.id }
        activeID = tab.id
    }

    func closeAll() {
        for tab in tabs { rememberClosed(tab) }
        tabs.removeAll()
        newTab()
    }

    // MARK: - Recently closed

    private func rememberClosed(_ tab: BrowserModel) {
        guard !tab.isPrivate, let url = tab.sessionURL else { return }
        let title = tab.pageTitle.isEmpty ? (url.host ?? url.absoluteString) : tab.pageTitle
        recentlyClosed.insert(ClosedTab(url: url, title: title), at: 0)
        if recentlyClosed.count > Self.recentlyClosedCap {
            recentlyClosed.removeLast(recentlyClosed.count - Self.recentlyClosedCap)
        }
    }

    func reopen(_ closed: ClosedTab) {
        recentlyClosed.removeAll { $0.id == closed.id }
        newTab(url: closed.url)
    }

    func reopenMostRecent() {
        guard let first = recentlyClosed.first else { return }
        reopen(first)
    }

    // MARK: - Fire (burn the session)

    /// DuckDuckGo-style fire button: closes every tab (normal and private), forgets the
    /// recently-closed list, and erases all website data (cookies, caches, storage) plus
    /// cached favicons. History/bookmarks are separate, user-controlled data — untouched.
    func burn() {
        tabs.removeAll()
        recentlyClosed.removeAll()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        FaviconStore.shared.clearAll()
        newTab()
        Haptics.tap()
    }
}
