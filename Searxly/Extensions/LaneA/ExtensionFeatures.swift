//
//  ExtensionFeatures.swift
//  Searxly
//
//  Feature flags for Lane A (real WebExtensions). Kept separate so the engine can be wired into the live
//  browser while staying OFF for normal users until the curated gallery + permission UI ship.
//

import Foundation

enum ExtensionFeatures {
    private static let laneAKey = "extLaneAEnabled"

    /// RELEASE KILL SWITCH for the whole Extensions program — Lane A (WebExtensions), Lane B
    /// (userscripts), and every UI entry point (Settings pane, ☰ menu row, app-menu command,
    /// marketplace tab, restored Extensions tabs). While `false` the managers no-op, nothing is ever
    /// injected or attached, and the feature is invisible in the UI.
    /// OFF again 2026-07-19: dropping the Chrome Web Store third-party path. WebKit can't run a large
    /// slice of real extensions (offscreen/sidePanel/devtools unimplemented; popup config UIs hang on
    /// their service worker), so shipping CWS installs would be a broken promise. Plan: build our own
    /// first-party extensions/features instead until Apple's WKWebExtension matures. The engine + install
    /// code stays compiled (behind this flag) for when we bring our own set online.
    static let programEnabled = false

    /// Master flag for Lane A (the real `WKWebExtension` engine). **Default OFF.**
    ///
    /// While off, the shared `WKWebExtensionController` is never created and is never attached to any
    /// webview, so Lane A has zero effect on normal browsing. Toggled in Developer Mode during bring-up;
    /// will be replaced by the curated-gallery install state once that ships. Lane B userscripts are
    /// independent of this flag. Always false while `programEnabled` is off.
    static var laneAEnabled: Bool {
        get { programEnabled && UserDefaults.standard.bool(forKey: laneAKey) }
        set { UserDefaults.standard.set(newValue, forKey: laneAKey) }
    }
}
