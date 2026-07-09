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

import Foundation

enum AmnesiaMode {
    private static let key = "Amnesia.Enabled"

    /// The enforced flag for THIS session — resolved once, at first access (launch). Read this from
    /// enforcement points (Persistence, WebViewFactory, search history). Amnesic mode is a Searxly
    /// Maximum edition feature, so it is never active in the base app (even with a stale preference).
    static let isActive: Bool = Edition.isMaximum && UserDefaults.standard.bool(forKey: key)

    /// The user's persisted choice. May differ from `isActive` until the next launch.
    static var preference: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// True when the user has turned amnesia on but hasn't relaunched yet (so it isn't enforced).
    static var pendingRelaunch: Bool { preference && !isActive }
}
