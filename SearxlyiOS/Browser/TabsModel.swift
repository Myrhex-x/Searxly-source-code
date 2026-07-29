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
    var activeID: UUID {
        didSet {
            // Remember where we were in each space so toggling Private Mode returns you there.
            // Property observers don't fire during init, so session restore is unaffected.
            guard let t = tabs.first(where: { $0.id == activeID }) else { return }
            if t.isPrivate { lastActivePrivateID = activeID } else { lastActiveNormalID = activeID }
        }
    }

    /// App-wide Private Mode — Safari's two-space model. Session-only: NEVER persisted, always
    /// false at launch. While on, the UI shows only private tabs; normal tabs stay in `tabs`,
    /// preserved but hidden (and vice-versa). The invariant every screen relies on is that while
    /// `privateMode` is on, `active.isPrivate` is always true — which flips all the indigo chrome
    /// for free. Leaving the mode WIPES every private tab and its data (the user's choice).
    private(set) var privateMode = false

    /// Last active tab in each space, so a toggle returns you where you were.
    @ObservationIgnored private var lastActiveNormalID: UUID?
    @ObservationIgnored private var lastActivePrivateID: UUID?

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

    // MARK: - Private Mode (the app-wide two-space toggle)

    /// Enter Private Mode: hide the normal tabs, show the private space (minting a tab if empty).
    func enterPrivateMode() {
        guard !privateMode else { return }
        active.captureSnapshot()            // keep the outgoing normal tab's grid card fresh
        privateMode = true
        if privateTabsLocked {
            // Existing private tabs are Face-ID-locked — don't reveal one by activating it.
            // Start fresh; the locked tabs stay frosted in the switcher until unlocked.
            newTab()
        } else if let target = preferredActiveID(wantPrivate: true) {
            activeID = target
            active.reviveIfNeeded()
        } else {
            newTab()                        // empty private space → mint one (inherits privateMode)
        }
    }

    /// Leave Private Mode. `discard` (the default) WIPES every private tab and its data — the
    /// user chose "closing it is as if it never happened". Passing `discard: false` keeps the
    /// private tabs for the session (Safari behavior) — kept as a one-line switch for later.
    func exitPrivateMode(discard: Bool = true) {
        guard privateMode else { return }
        active.captureSnapshot()
        privateMode = false
        if discard {
            tabs.removeAll { $0.isPrivate }
            lastActivePrivateID = nil
            privateTabsRevealed = false
            BrowserModel.wipePrivateData()
        }
        if let target = preferredActiveID(wantPrivate: false) {
            activeID = target
            active.reviveIfNeeded()
        } else {
            newTab()                        // empty normal space → mint one
        }
    }

    func togglePrivateMode() { privateMode ? exitPrivateMode() : enterPrivateMode() }

    /// Prefer the space's remembered last-active tab, else its most recent; nil if the space is empty.
    private func preferredActiveID(wantPrivate: Bool) -> UUID? {
        let want = tabs.filter { $0.isPrivate == wantPrivate }
        guard !want.isEmpty else { return nil }
        let remembered = wantPrivate ? lastActivePrivateID : lastActiveNormalID
        if let remembered, want.contains(where: { $0.id == remembered }) { return remembered }
        return want.last?.id
    }

    /// Link-menu "Open in Private Tab": switch into Private Mode (if needed) and open the URL there,
    /// leaving no stray blank private tab behind.
    func openInPrivateMode(url: URL) {
        if !privateMode {
            active.captureSnapshot()
            privateMode = true
        }
        newTab(url: url)                    // inherits privateMode == true
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
                self?.setMediaPlaybackSuspended(true, exempting: self?.backgroundMediaExemption)
                // Park non-active web tabs so WebKit process memory / JS timers cool down in background.
                // Active tab stays live so returning is instant; others revive on first switch.
                self?.hibernateBackgroundTabs()
                LibraryStore.shared.flushPersist()
                ShieldSettings.shared.flushStatsPersist()
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
    /// suspends the app, which also stops every background task, timer, and animation.
    ///
    /// `exempting` is the one tab allowed to keep playing (Background Media / Picture in Picture).
    /// Everything else is paused exactly as before, so an autoplaying background tab can still
    /// never be the thing holding the app awake.
    private func setMediaPlaybackSuspended(_ suspended: Bool, exempting exempt: UUID? = nil) {
        for tab in tabs {
            if suspended {
                // `continue` skips BOTH calls: setAllMediaPlaybackSuspended(true) halts playback on
                // its own, so the exempt tab must not reach it either.
                if tab.id == exempt { continue }
                tab.webView.pauseAllMediaPlayback(completionHandler: nil)
            }
            tab.webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
        }
    }

    /// Which tab, if any, may keep playing while the app is in the background.
    ///
    /// Picture in Picture counts on its own: putting a video in the floating window is a clearer
    /// statement of "keep this playing" than any setting, and killing it the moment the user swipes
    /// home would make the feature pointless. Otherwise it takes the explicit opt-in — and in both
    /// cases the tab must ALREADY be playing, so merely having YouTube open in the background costs
    /// nothing.
    private var backgroundMediaExemption: UUID? {
        guard let tab = tabs.first(where: { $0.id == activeID }), tab.isPlayingMedia else { return nil }
        guard SearchSettings.shared.backgroundMedia || tab.isInPictureInPicture else { return nil }
        return tab.id
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
        tabs.first { $0.id == activeID } ?? spaceTabs.first ?? tabs[0]
    }

    var activeIndex: Int { tabs.firstIndex { $0.id == activeID } ?? 0 }

    var hasPrivateTabs: Bool { tabs.contains { $0.isPrivate } }

    /// Tabs in the CURRENT space (normal or private, per `privateMode`). Every tab-list surface —
    /// the switcher grid, the count, swipe prev/next — iterates this, never `tabs` directly.
    var spaceTabs: [BrowserModel] { tabs.filter { $0.isPrivate == privateMode } }

    /// The active tab's index within the current space.
    var activeSpaceIndex: Int { spaceTabs.firstIndex { $0.id == activeID } ?? 0 }

    /// `isPrivate: nil` (the default) inherits the current space — a bare `newTab()` is private
    /// while Private Mode is on, normal otherwise. Callers that need a specific kind still pass a
    /// Bool (Swift promotes it to `Bool?`), so every existing call site keeps working.
    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool? = nil) -> BrowserModel {
        let tab = BrowserModel(isPrivate: isPrivate ?? privateMode)
        wire(tab)
        tabs.append(tab)
        activeID = tab.id
        if let url { tab.load(url) }
        return tab
    }

    /// Opens a tab in the background — appended and loaded, but the active tab stays put
    /// (queue links while reading, Safari-style).
    func newTabInBackground(url: URL, isPrivate: Bool? = nil) {
        let tab = BrowserModel(isPrivate: isPrivate ?? privateMode)
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

    /// Swipe-to-switch (Safari-style horizontal swipe on the bottom bar) — within the current space.
    func switchToPrevious() {
        let s = spaceTabs
        guard let i = s.firstIndex(where: { $0.id == activeID }), i > 0 else { return }
        active.captureSnapshot()
        activeID = s[i - 1].id
        active.reviveIfNeeded()
        Haptics.tick()
    }

    func switchToNext() {
        let s = spaceTabs
        guard let i = s.firstIndex(where: { $0.id == activeID }), i < s.count - 1 else { return }
        active.captureSnapshot()
        activeID = s[i + 1].id
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
            self?.openInPrivateMode(url: url)
        }
    }

    /// Closing is space-aware: a closed tab's slot is refilled only within ITS space, and emptying
    /// the CURRENT space mints a replacement there (the hidden other space is left untouched).
    func close(_ tab: BrowserModel) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        rememberClosed(tab)                                     // already skips private tabs
        let wasActive = tab.id == activeID
        let sameSpace = tab.isPrivate == privateMode
        let sIdx = spaceTabs.firstIndex { $0.id == tab.id }     // space-relative, before removal
        tabs.removeAll { $0.id == tab.id }
        guard sameSpace else { return }                        // closed a hidden other-space tab: done
        let remaining = spaceTabs
        if remaining.isEmpty {
            newTab()                                           // refill the current space only
        } else if wasActive, let sIdx {
            activeID = remaining[min(sIdx, remaining.count - 1)].id
            active.reviveIfNeeded()
        }
    }

    func closeOthers(keeping tab: BrowserModel) {
        for other in spaceTabs where other.id != tab.id { rememberClosed(other) }
        tabs.removeAll { $0.id != tab.id && $0.isPrivate == tab.isPrivate }   // same space only
        activeID = tab.id
    }

    func closeAll() {
        for t in spaceTabs { rememberClosed(t) }
        tabs.removeAll { $0.isPrivate == privateMode }         // current space only
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
        // Reopened tabs are always normal (private ones are never remembered); leave Private Mode
        // first so the restored tab lands in — and shows in — the normal space.
        if privateMode { exitPrivateMode() }
        newTab(url: closed.url, isPrivate: false)
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
        privateMode = false
        lastActiveNormalID = nil
        lastActivePrivateID = nil
        privateTabsRevealed = false
        tabs.removeAll()
        recentlyClosed.removeAll()
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        BrowserModel.wipePrivateData()
        FaviconStore.shared.clearAll()
        newTab()
        Haptics.tap()
    }
}
