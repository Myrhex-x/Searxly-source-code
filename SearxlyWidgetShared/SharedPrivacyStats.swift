//
//  SharedPrivacyStats.swift
//  SearxlyiOS
//
//  Bridges the lifetime "trackers blocked" count from the app to the Home Screen widget through a
//  shared App Group container — a widget runs in its own process and can't read the app's standard
//  UserDefaults. Both the app and the widget extension compile this one file; the app writes, the
//  widget reads. Nothing leaves the device (App Groups are a local, sandboxed container).
//
//  NOTE: the widget only shows a live number once the App Group capability
//  `group.com.myrhex.searxly` is enabled on BOTH targets. Without it, `UserDefaults(suiteName:)`
//  falls back to a private store and the count reads 0 — harmless, just not shared.
//

import Foundation

enum SharedPrivacyStats {
    /// Must match the App Group capability added to BOTH the app and the widget target.
    static let appGroup = "group.com.myrhex.searxly"
    private static let lifetimeBlockedKey = "lifetimeTrackersBlocked"

    private static var store: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// App side: mirror the current lifetime count into the shared container.
    static func setLifetimeBlocked(_ count: Int) {
        store?.set(count, forKey: lifetimeBlockedKey)
    }

    /// Widget side: read the last mirrored count (0 if never written / App Group not enabled).
    static var lifetimeBlocked: Int {
        store?.integer(forKey: lifetimeBlockedKey) ?? 0
    }
}
