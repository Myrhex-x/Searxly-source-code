//
//  SearxlyiOSApp.swift
//  SearxlyiOS
//
//  iOS app entry point. This is a dedicated iOS target that will share the macOS
//  codebase incrementally (starting in Phase 1). Kept deliberately minimal for now so the
//  iOS target builds and launches on its own before any shared code is wired in.
//
//  macOS-only subsystems (wallet, Tor, the privileged helper / XPC, the bundled SearXNG
//  Python runtime, Sparkle) are intentionally NOT part of this target.
//

import SwiftUI
import WebKit

@main
struct SearxlyiOSApp: App {
    // Catches home-screen Quick Actions (long-press the app icon) and routes them into the browser.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start compiling the uBlock filter lists immediately — WebKit caches the compiled
        // rules, so this is expensive exactly once per filter-list version.
        ContentBlockManager.shared.prepare()

        // "Clear on Exit": wipe whatever website data the previous session left behind, before
        // any web view touches the store. (Tabs never persist across launches, so launch-time
        // wiping IS the exit semantics — without fighting iOS's unreliable termination hooks.)
        if ShieldSettings.shared.clearDataOnExit {
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {}
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Keep the Spotlight bookmark index fresh — deferred to first appear so the
                // initial rebuild never competes with launch / first paint.
                .task { SpotlightIndexer.reindexBookmarks() }
        }
    }
}
