//
//  AmnesiaMode.swift
//  Searxly
//
//  Amnesic / RAM-only browsing (Tails-style). When on, a session leaves no trace on disk: browsing
//  history, open-tab snapshots, cookies, cache, localStorage, and new search-history entries all live
//  in memory only and are gone the moment you quit. User ASSETS — bookmarks, saved passwords, your
//  configured search instances, and settings — are deliberately kept; amnesia forgets what you DID,
//  not what you own.
//
//  It's a "boot into it" mode: the enforced flag is a snapshot taken once at launch, so you never end
//  up with a half-amnesic session (some tabs RAM-only, others persisted). Flipping the toggle updates
//  the preference and takes full effect on the next launch.
//

import AppKit
import Foundation

enum AmnesiaMode {
    private static let key = "Amnesia.Enabled"

    /// The enforced flag for THIS session — resolved once, at first access (launch). Read this from
    /// enforcement points (Persistence, WebViewFactory, search history). Amnesic mode is a Searxly
    /// Maximum edition feature, so it is never active in the base app (even with a stale preference).
    /// `nonisolated`: read from the nonisolated download-destination path (DownloadBridge) as well as
    /// main-actor call sites — it's an immutable snapshot, safe from any isolation.
    nonisolated static let isActive: Bool = Edition.isMaximum && UserDefaults.standard.bool(forKey: key)

    /// The user's persisted choice. May differ from `isActive` until the next launch.
    static var preference: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// True when the user has turned amnesia on but hasn't relaunched yet (so it isn't enforced).
    static var pendingRelaunch: Bool { preference && !isActive }

    // MARK: - Session-scoped downloads

    /// Where downloads land during an amnesic session instead of ~/Downloads. A file saved to
    /// ~/Downloads is the one artifact amnesia didn't cover: it outlives the session, Spotlight
    /// indexes its content, Finder keeps it. Session downloads live in the app container's temp
    /// area instead — wiped on quit, swept at the next launch — and the Downloads sheet offers
    /// "Keep" to deliberately move one to ~/Downloads.
    /// `nonisolated`: the download-destination picker (DownloadBridge, nonisolated) reads this.
    nonisolated static let sessionDownloadsDirectory: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("AmnesicDownloads", isDirectory: true)

    /// Call once at launch. Every launch sweeps leftovers a crashed amnesic session may have left
    /// behind; when THIS session is amnesic, it also wipes the session downloads on quit.
    /// Honest limits: the bytes touch disk while the session runs (container temp, not RAM), and
    /// removal is not a secure erase — FileVault (checked by the Privacy Self-Test) is what protects
    /// the freed blocks at rest.
    @MainActor
    static func installSessionDownloadsHygiene() {
        guard Edition.isMaximum else { return }
        try? FileManager.default.removeItem(at: sessionDownloadsDirectory)
        guard isActive else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            try? FileManager.default.removeItem(at: sessionDownloadsDirectory)
        }
    }
}
