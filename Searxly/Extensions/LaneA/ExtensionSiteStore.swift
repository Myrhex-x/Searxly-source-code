//
//  ExtensionSiteStore.swift
//  Searxly
//
//  Per-extension, per-site on/off — the control behind the address-bar globe popover (you can see your
//  installed extensions there and pause an individual one on the current site). Persisted in UserDefaults
//  as a map of extensionID → the hosts where THAT extension is paused (default: each runs everywhere).
//  15.0-safe so the popover (a 15.0 view) can read/write it without touching the 15.4-only engine; the
//  engine re-applies it as denied match patterns whenever an extension loads.
//

import Foundation

enum ExtensionSiteStore {
    private static let key = "extPausedHostsByExtension"   // [extensionID: [host]]

    private static func map() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    private static func save(_ map: [String: [String]]) {
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Hosts where a given extension is paused.
    static func pausedHosts(forExtension extensionID: String) -> Set<String> {
        Set(map()[extensionID] ?? [])
    }

    /// Whether a given extension is allowed to run on a host (true = runs, false = paused here).
    static func isEnabled(extensionID: String, host: String) -> Bool {
        !pausedHosts(forExtension: extensionID).contains(host.lowercased())
    }

    static func setEnabled(_ enabled: Bool, extensionID: String, host: String) {
        let normalized = host.lowercased()
        var m = map()
        var hosts = Set(m[extensionID] ?? [])
        if enabled { hosts.remove(normalized) } else { hosts.insert(normalized) }
        if hosts.isEmpty { m.removeValue(forKey: extensionID) } else { m[extensionID] = Array(hosts) }
        save(m)
    }
}
