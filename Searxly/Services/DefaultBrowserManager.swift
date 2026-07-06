//
//  DefaultBrowserManager.swift
//  Searxly
//
//  Reports whether Searxly is the system default web browser and asks the OS to make it so.
//
//  Pairs with the CFBundleURLTypes (http/https) declaration in the app's Info.plist: without that
//  declaration macOS won't list Searxly as an eligible browser, so this would have nothing to set.
//  Links opened from other apps once Searxly is default are delivered to `.onOpenURL` in SearxlyApp
//  and routed to a new tab via BrowserState.openExternalURL.
//

import AppKit
import os

@MainActor
@Observable
final class DefaultBrowserManager {
    static let shared = DefaultBrowserManager()
    private init() { refresh() }

    /// True when this build is the registered default handler for https.
    private(set) var isDefault: Bool = false

    /// Re-reads the current default handler. Call on appear / on app-activate so the UI stays accurate
    /// after the user changes the default in System Settings or via `makeDefault()`.
    func refresh() {
        guard let probe = URL(string: "https://searxly.app") else { isDefault = false; return }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL
        isDefault = (handler == Bundle.main.bundleURL.standardizedFileURL)
    }

    /// Asks macOS to make Searxly the default browser for http + https. The OS presents its own
    /// confirmation dialog; we re-check the outcome once both scheme requests return.
    func makeDefault() {
        let me = Bundle.main.bundleURL
        let group = DispatchGroup()
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: scheme) { error in
                if let error {
                    Log.app.error("Set default browser for \(scheme, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // notify runs on the main queue; assumeIsolated lets us touch the @MainActor singleton
            // without capturing self into the @Sendable closure (a Swift 6 concurrency error otherwise).
            MainActor.assumeIsolated { DefaultBrowserManager.shared.refresh() }
        }
    }
}
