//
//  OperationalSecurity.swift
//  Searxly
//
//  Three Searxly Maximum operational-security controls. Each closes a leak that lives OUTSIDE the
//  web engine — in the OS around the browser — which is why no amount of WebKit hardening reaches
//  them:
//
//    • Uniform locale — WKWebView's Accept-Language header derives from AppleLanguages, which the
//      JS locale pinning can't reach: a French system sent "fr-FR" on every request even while
//      navigator.language read "en-US" — leaking the real locale AND advertising the mismatch
//      (itself a fingerprint). Pinning AppleLanguages to en-US closes both. Cost: the app UI runs
//      in English (Tor Browser ships the same trade). An explicit Settings → Language choice always
//      wins — the pin never fights it.
//
//    • Screen-capture exclusion — renders every Searxly window black in screenshots, screen
//      recordings, and shared screens (Zoom/Teams/…), so browsing can't leak through a capture.
//      Cost: the user's own screenshots of Searxly stop working too — strictly opt-in.
//
//    • Secure keyboard entry — while the address bar is focused, other processes' event taps can't
//      read the keystrokes (what gets typed into a search browser is its single most sensitive
//      input). Terminal's "Secure Keyboard Entry", scoped to the field that matters. Cost: text
//      expanders and keystroke-driven utilities pause while the field is focused.
//

import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Uniform locale (Accept-Language)

@MainActor
enum UniformLocale {
    private static let key = "Maximum.UniformLocale"

    /// On by default in Searxly Maximum (privacy-first defaults, same trade Tor Browser ships).
    /// Never meaningful in the base app.
    static var enabled: Bool {
        get { Edition.isMaximum && (UserDefaults.standard.object(forKey: key) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    /// True when an explicit Settings → Language choice takes precedence over the pin.
    static var overriddenByLanguageChoice: Bool { AppLanguage.override != nil }

    /// Call very early at launch (before any web view exists). Fully consistent — UI strings,
    /// Foundation formatters, and the Accept-Language header together — from the next launch,
    /// matching how the app's own language override applies.
    static func applyAtLaunch() {
        guard Edition.isMaximum else { return }
        apply()
    }

    private static func apply() {
        // An explicit in-app language choice owns AppleLanguages (AppLanguage.setOverride) — the
        // pin must never stomp it, in either direction.
        guard AppLanguage.override == nil else { return }
        let defaults = UserDefaults.standard
        if enabled {
            defaults.set(["en-US", "en"], forKey: "AppleLanguages")
        } else if let pinned = defaults.array(forKey: "AppleLanguages") as? [String],
                  pinned == ["en-US", "en"] {
            // Only unwind OUR pin — never a value some other path wrote.
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

// MARK: - Screen-capture exclusion

@MainActor
enum CaptureExclusion {
    private static let key = "Maximum.CaptureExclusion"
    private static var observer: NSObjectProtocol?

    /// Off by default: it also blacks out the user's OWN screenshots and screen shares, so it must
    /// be a deliberate choice.
    static var enabled: Bool {
        get { Edition.isMaximum && UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            applyToAllWindows()
        }
    }

    /// The sharing type a window should rest at when no secret view is forcing `.none` — consulted
    /// by ScreenCaptureProtector's restore so dismissing a revealed password doesn't re-expose the
    /// window while exclusion is on.
    static var restingSharingType: NSWindow.SharingType { enabled ? .none : .readOnly }

    /// Call once at launch. Windows don't exist yet at App.init, so the key-window observer is what
    /// actually reaches them as they appear.
    static func install() {
        guard Edition.isMaximum, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                          object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if enabled { window.sharingType = .none }
            }
        }
    }

    static func applyToAllWindows() {
        guard Edition.isMaximum else { return }
        // Toggling off returns every window to the default. A secret view that is on screen at that
        // exact moment re-protects itself on its next SwiftUI update (ScreenCaptureProtector).
        for window in NSApp.windows { window.sharingType = restingSharingType }
    }
}

// MARK: - Secure keyboard entry (address bar)

@MainActor
enum SecureInputGuard {
    private static let key = "Maximum.SecureKeyboardEntry"
    private static var active = false

    /// On by default in Searxly Maximum: typed queries are the crown-jewel input, and the cost
    /// (text expanders pause while the field is focused) is narrow.
    static var enabled: Bool {
        get { Edition.isMaximum && (UserDefaults.standard.object(forKey: key) as? Bool ?? true) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            if !newValue { deactivate() }
        }
    }

    /// Funnel from BrowserState: every address-bar focus change lands here. Enable/Disable calls
    /// must balance exactly, so all transitions run through activate()/deactivate() and the OS
    /// clears the flag if the process exits while the field is focused.
    static func setAddressBarFocused(_ focused: Bool) {
        guard Edition.isMaximum else { return }
        if focused && enabled { activate() } else { deactivate() }
    }

    private static func activate() {
        guard !active else { return }
        active = true
        EnableSecureEventInput()
    }

    private static func deactivate() {
        guard active else { return }
        active = false
        DisableSecureEventInput()
    }
}
