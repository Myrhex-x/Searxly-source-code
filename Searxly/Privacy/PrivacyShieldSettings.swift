//
//  PrivacyShieldSettings.swift
//  Searxly
//
//  User preferences for the request-level shields (NavigationGuard): tracking-parameter stripping,
//  Global Privacy Control, and HTTPS-Only. All default ON — these are safe, low-breakage protections.
//  In Searxly Maximum they are on and non-negotiable (the edition's whole premise is that request
//  hygiene isn't optional); in the base app the user can turn them off.
//

import Foundation
import Observation

@MainActor
@Observable
final class PrivacyShieldSettings {
    static let shared = PrivacyShieldSettings()

    private enum Key {
        static let strip = "Shields.StripTrackingParams"
        static let gpc = "Shields.GPC"
        static let https = "Shields.HTTPSOnly"
    }

    private init() {
        let d = UserDefaults.standard
        // Default true when unset.
        _stripTrackingParams = (d.object(forKey: Key.strip) as? Bool) ?? true
        _gpcSignal = (d.object(forKey: Key.gpc) as? Bool) ?? true
        _httpsOnly = (d.object(forKey: Key.https) as? Bool) ?? true
    }

    // Backing storage + effective getters. In Maximum the shields are forced on regardless of the
    // stored value, so the enforcement paths can read the effective properties directly.

    private var _stripTrackingParams: Bool
    var stripTrackingParams: Bool {
        get { Edition.isMaximum || _stripTrackingParams }
        set { _stripTrackingParams = newValue; UserDefaults.standard.set(newValue, forKey: Key.strip) }
    }

    private var _gpcSignal: Bool
    var gpcSignal: Bool {
        get { Edition.isMaximum || _gpcSignal }
        set { _gpcSignal = newValue; UserDefaults.standard.set(newValue, forKey: Key.gpc) }
    }

    private var _httpsOnly: Bool
    var httpsOnly: Bool {
        get { Edition.isMaximum || _httpsOnly }
        set { _httpsOnly = newValue; UserDefaults.standard.set(newValue, forKey: Key.https) }
    }

    /// Whether the toggles are locked (Maximum locks them on).
    var isLocked: Bool { Edition.isMaximum }
}
