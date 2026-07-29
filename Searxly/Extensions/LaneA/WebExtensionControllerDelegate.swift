//
//  WebExtensionControllerDelegate.swift
//  Searxly
//
//  The controller delegate for Lane A. Its job in Phase 2 is the privacy posture: every RUNTIME
//  permission escalation an extension requests (the `permissions.request` / optional-host-access APIs)
//  is **denied by default**, because there is no approval UI yet (Phase 3). Manifest-declared content
//  scripts are unaffected — those run only on hosts the user explicitly granted at install time
//  (ExtensionManager applies those to the context), never through these prompts.
//
//  All delegate methods are optional; we implement only the permission prompts here. Tab/window opening
//  and action popups are added when the live BrowserState wiring + store UI land.
//

import Foundation
import WebKit
import os

@available(macOS 15.4, *)
@MainActor
final class WebExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        Log.web.info("[WebExt] denied runtime permission request: \(permissions.map(\.rawValue).joined(separator: ", "), privacy: .public) (no approval UI yet)")
        completionHandler([], nil)   // default-deny
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        Log.web.info("[WebExt] denied runtime URL-access request (\(urls.count, privacy: .public) URL(s))")
        completionHandler([], nil)   // default-deny
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        Log.web.info("[WebExt] denied runtime host-pattern request: \(matchPatterns.map(\.string).joined(separator: ", "), privacy: .public)")
        completionHandler([], nil)   // default-deny
    }

    // MARK: - Browser action

    /// The extension's toolbar action changed (icon, badge, enabled). Nudge the header to refresh.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
    }

    /// The engine wants to present an action's popup — either because the user clicked the toolbar
    /// button (via `activateAction`) or an engine-initiated open (keyboard command / `action.openPopup()`).
    /// Show the engine's OWN `popupPopover`, which has its messaging port wired to the background —
    /// the reason we present it here rather than hosting `popupWebView` in a SwiftUI popover ourselves.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover,
              let anchor = ExtensionManager.shared.takePopoverAnchor(for: context.uniqueIdentifier) else {
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    // MARK: - Opening tabs / windows / options

    /// `chrome.tabs.create` / a link opened from a popup or background page. Open it as a Searxly tab.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        if let url = configuration.url {
            NotificationCenter.default.post(
                name: .openURLInNewTab, object: url,
                userInfo: ["background": !configuration.shouldBeActive]
            )
        } else {
            NotificationCenter.default.post(name: .laneANewTabRequested, object: nil)
        }
        // We open the tab for the user but can't synchronously hand back a tab adapter (BrowserState
        // creates it asynchronously). Extensions that don't await the returned tab still work.
        completionHandler(nil, nil)
    }

    /// We're single-window; treat `chrome.windows.create` as opening tab(s) in the current window.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        for url in configuration.tabURLs {
            NotificationCenter.default.post(name: .openURLInNewTab, object: url, userInfo: ["background": true])
        }
        completionHandler(nil, nil)
    }

    /// The extension's options page ("Extension options" / `chrome.runtime.openOptionsPage`).
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = context.optionsPageURL {
            NotificationCenter.default.post(name: .openURLInNewTab, object: url, userInfo: ["background": false])
        }
        completionHandler(nil)
    }
}
