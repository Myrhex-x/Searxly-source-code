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
}
