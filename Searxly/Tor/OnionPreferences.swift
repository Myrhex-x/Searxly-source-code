//
//  OnionPreferences.swift
//  Searxly
//
//  User preferences for how Searxly treats sites that advertise a Tor `.onion` mirror
//  (Onion-Location). Kept tiny and UserDefaults-backed.
//

import Foundation

enum OnionPreferences {
    private static let autoUpgradeKey = "Tor.OnionAutoUpgrade"

    /// When on, a site that advertises an `.onion` mirror is opened automatically instead of merely
    /// offering a banner. Onion services are end-to-end encrypted and never touch an exit node, so this
    /// is a privacy win. Auto-upgrade is a Searxly Maximum edition feature: it is never on in the base
    /// app (which keeps only the offer banner), and defaults ON in Maximum. Persists an explicit choice.
    static var autoUpgrade: Bool {
        get {
            guard Edition.isMaximum else { return false }
            return UserDefaults.standard.object(forKey: autoUpgradeKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoUpgradeKey) }
    }
}
