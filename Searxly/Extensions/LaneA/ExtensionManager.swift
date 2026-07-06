//
//  ExtensionManager.swift
//  Searxly
//
//  Lane A runtime. The @MainActor singleton that owns the ONE shared `WKWebExtensionController` for the
//  browser session and the set of loaded extensions. Productionizes the Phase 0 spike: same load path,
//  but a single shared controller that `WebViewFactory` attaches to standard tabs so installed
//  extensions' content scripts run on real pages.
//
//  Gated `@available(macOS 15.4, *)` and only ever touched behind `ExtensionFeatures.laneAEnabled`
//  (default OFF) — so for normal users the controller is never even created.
//
//  Scope note: this handles loading extensions + attaching the controller (which drives content-script
//  injection). The richer `chrome.tabs`/`chrome.windows` API needs the live BrowserState lifecycle wired
//  to `registerTab`/`setActiveTab` below — that's the next step and wants a macOS 15.4 runtime test.
//  See Extensions/EXTENSION_IMPLEMENTATION_NOTES.md.
//

import Foundation
import WebKit
import os

/// A plain, availability-unrestricted view of a loaded Lane A extension, so SwiftUI (which targets
/// macOS 15.0) can list and act on extensions without importing the 15.4-only `WKWebExtension*` types.
struct LaneAExtensionSnapshot: Identifiable {
    let id: UUID
    let extensionID: String
    let displayName: String
    let requestedPermissions: [String]
    let requestedHosts: [String]
    let grantedHostCount: Int
}

/// 15.0-safe launch entry. Reloads installed extensions ONLY when the user actually has some — so the
/// `WKWebExtensionController` is never created for users who have installed nothing. Call from app init.
enum ExtensionBootstrap {
    static func run() {
        guard ExtensionFeatures.programEnabled else { return }
        guard ExtensionInstallStore.hasInstalled() else { return }
        if #available(macOS 15.4, *) {
            Task { @MainActor in await ExtensionManager.shared.reloadInstalled() }
        }
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionManager {
    static let shared = ExtensionManager()

    /// A loaded, active extension.
    struct Loaded: Identifiable {
        let id: UUID
        /// Stable key used for persisted grants + WebKit's own storage.
        let extensionID: String
        let displayName: String
        let requestedPermissions: [String]
        let requestedHosts: [String]
        let context: WKWebExtensionContext
        /// How many host patterns are currently granted (default-deny = 0 until the user approves).
        var grantedHostCount: Int { context.grantedPermissionMatchPatterns.count }
    }

    /// The single controller for the whole browser session.
    let controller: WKWebExtensionController

    private(set) var loaded: [Loaded] = []

    /// Default-deny permission delegate (denies runtime escalations until the approval UI exists).
    /// Held strongly — the controller keeps only a weak reference.
    private let permissionDelegate = WebExtensionControllerDelegate()

    /// One window adapter representing the browser window; reports the tabs the manager is tracking.
    private let window = WebExtensionWindowAdapter()
    /// Tab adapters keyed by their WKWebView identity.
    private var tabAdapters: [ObjectIdentifier: WebExtensionTabAdapter] = [:]
    private weak var activeWebView: WKWebView?

    private init() {
        controller = WKWebExtensionController()
        controller.delegate = permissionDelegate
        window.tabsProvider = { [weak self] in
            guard let self else { return [] }
            return Array(self.tabAdapters.values)
        }
        window.activeTabProvider = { [weak self] in
            guard let self, let wv = self.activeWebView else { return nil }
            return self.tabAdapters[ObjectIdentifier(wv)]
        }
        controller.didOpenWindow(window)
    }

    // MARK: - Webview attachment (the WebViewFactory hook)

    /// Attaches the shared controller to a standard-tab configuration so extensions can run on it.
    /// No-op unless the Lane A flag is on AND the tab is `.standard` (never Private/Onion).
    func configure(_ configuration: WKWebViewConfiguration, mode: TabPrivacyMode) {
        guard ExtensionFeatures.laneAEnabled, mode == .standard else { return }
        configuration.webExtensionController = controller
    }

    // MARK: - Loading extensions

    /// Loads + activates a WebExtension. **Default-deny:** it grants only what the user previously
    /// approved (persisted in `WebExtensionPermissionStore`), nothing else — so a freshly-installed
    /// extension can read no hosts until approved. `grantRequestedHosts: true` is a bring-up convenience
    /// (the Dev "Load test extension" path) that grants exactly the hosts the manifest requests and records
    /// them. The real approval UI (Phase 3) will call `grantRequestedHosts(for:)` / `revokeAll(for:)`.
    @discardableResult
    func load(directory: URL, id: String? = nil, grantRequestedHosts: Bool = false) async throws -> Loaded {
        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: ext)

        let extID = id ?? ext.displayName ?? (ext.manifest["name"] as? String) ?? UUID().uuidString
        context.uniqueIdentifier = extID

        let requestedHosts = ext.allRequestedMatchPatterns.map { $0.string }
        let requestedPermissions = ext.requestedPermissions.map { $0.rawValue }

        if grantRequestedHosts {
            applyHostGrants(ext.allRequestedMatchPatterns, to: context)
            WebExtensionPermissionStore.setGrant(
                WebExtensionGrant(hosts: requestedHosts, permissions: requestedPermissions),
                for: extID
            )
        } else if let recorded = WebExtensionPermissionStore.grant(for: extID) {
            // Re-apply previously approved host grants. Anything not recorded stays denied.
            let patterns = recorded.hosts.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
            applyHostGrants(Set(patterns), to: context)
        }

        try controller.load(context)

        let entry = Loaded(
            id: UUID(),
            extensionID: extID,
            displayName: ext.displayName ?? extID,
            requestedPermissions: requestedPermissions,
            requestedHosts: requestedHosts,
            context: context
        )
        loaded.append(entry)
        applySiteDisables(to: context)   // honor any per-site pauses the user set previously
        Log.web.info("[ExtensionManager] loaded \"\(entry.displayName, privacy: .public)\" — granted \(entry.grantedHostCount, privacy: .public)/\(requestedHosts.count, privacy: .public) host pattern(s)")
        return entry
    }

    // MARK: - Per-extension, per-site enable/disable (the address-bar globe popover)

    /// Whether a specific extension runs on a host (for the globe popover's per-extension toggles).
    func isExtensionEnabled(extensionID: String, forHost host: String) -> Bool {
        ExtensionSiteStore.isEnabled(extensionID: extensionID, host: host)
    }

    /// Pauses/resumes a single extension on a single host. Persists the choice and re-applies it live to
    /// that extension as denied match patterns. Reload the page to apply to an already-open tab.
    func setExtensionEnabled(_ enabled: Bool, extensionID: String, forHost host: String) {
        ExtensionSiteStore.setEnabled(enabled, extensionID: extensionID, host: host)
        for entry in loaded where entry.extensionID == extensionID {
            applySiteDisables(to: entry.context)
        }
    }

    /// Rebuilds a context's denied match patterns from the hosts where THAT extension is paused. An
    /// explicit deny overrides the extension's broad granted access (e.g. `<all_urls>`) on that host.
    private func applySiteDisables(to context: WKWebExtensionContext) {
        var denied: [WKWebExtension.MatchPattern: Date] = [:]
        for host in ExtensionSiteStore.pausedHosts(forExtension: context.uniqueIdentifier) {
            if let p = try? WKWebExtension.MatchPattern(string: "*://\(host)/*") { denied[p] = Date.distantFuture }
            if let p = try? WKWebExtension.MatchPattern(string: "*://*.\(host)/*") { denied[p] = Date.distantFuture }
        }
        context.deniedPermissionMatchPatterns = denied
    }

    private func applyHostGrants(_ patterns: Set<WKWebExtension.MatchPattern>, to context: WKWebExtensionContext) {
        guard !patterns.isEmpty else { return }
        var grants = context.grantedPermissionMatchPatterns
        for pattern in patterns { grants[pattern] = Date.distantFuture }
        context.grantedPermissionMatchPatterns = grants
    }

    /// Grants the extension's requested hosts and persists the decision. For the future approval UI.
    func grantRequestedHosts(for entry: Loaded) {
        applyHostGrants(entry.context.webExtension.allRequestedMatchPatterns, to: entry.context)
        WebExtensionPermissionStore.setGrant(
            WebExtensionGrant(hosts: entry.requestedHosts, permissions: entry.requestedPermissions),
            for: entry.extensionID
        )
    }

    /// Revokes everything granted to the extension and forgets the persisted decision.
    func revokeAll(for entry: Loaded) {
        entry.context.grantedPermissionMatchPatterns = [:]
        WebExtensionPermissionStore.clear(id: entry.extensionID)
    }

    // MARK: - UI bridge (availability-unrestricted snapshots + id-based actions)

    /// A 15.0-safe snapshot of every loaded extension, for the approval UI.
    func snapshots() -> [LaneAExtensionSnapshot] {
        loaded.map {
            LaneAExtensionSnapshot(
                id: $0.id,
                extensionID: $0.extensionID,
                displayName: $0.displayName,
                requestedPermissions: $0.requestedPermissions,
                requestedHosts: $0.requestedHosts,
                grantedHostCount: $0.grantedHostCount
            )
        }
    }

    func grantRequestedHosts(forLoadedID id: UUID) {
        guard let entry = loaded.first(where: { $0.id == id }) else { return }
        grantRequestedHosts(for: entry)
    }

    func revokeAll(forLoadedID id: UUID) {
        guard let entry = loaded.first(where: { $0.id == id }) else { return }
        revokeAll(for: entry)
    }

    func unload(loadedID id: UUID) {
        guard let entry = loaded.first(where: { $0.id == id }) else { return }
        unload(entry)
    }

    // MARK: - Install / reload / uninstall (normal-user, persistent)

    static let demoExtensionID = "searxly.demo"

    /// Reloads every installed extension from `ExtensionInstallStore` (applies persisted grants;
    /// default-deny for anything not previously approved). Called once at launch via `ExtensionBootstrap`.
    func reloadInstalled() async {
        for record in ExtensionInstallStore.all() {
            // The resource is either a directory (built-in demo) or a `.zip` package (catalog installs) —
            // WKWebExtension accepts both. Just check the path still exists.
            let resource = URL(fileURLWithPath: record.directory)
            guard FileManager.default.fileExists(atPath: resource.path) else { continue }
            _ = try? await load(directory: resource, id: record.id)
        }
    }

    /// Installs a catalog extension: downloads + verifies (SHA-256 / signature) the package, records it,
    /// grants the hosts it requests (explicit user consent via install), and turns the engine on.
    @discardableResult
    func installFromCatalog(_ entry: ExtensionCatalogEntry) async throws -> Loaded {
        let pkg = try await ExtensionCatalogClient.downloadVerifiedPackage(entry)
        ExtensionInstallStore.add(InstalledExtensionRecord(
            id: entry.id, displayName: entry.name, directory: pkg.path, builtInDemo: false
        ))
        let loaded = try await load(directory: pkg, id: entry.id, grantRequestedHosts: true)
        ExtensionFeatures.laneAEnabled = true
        return loaded
    }

    /// Installs the bundled demo extension: writes it to Application Support, records it, grants the hosts
    /// it requests (the user is explicitly installing → consent), and turns the Lane A engine on so new
    /// standard tabs pick it up.
    func installBuiltInDemo() async throws {
        let dir = try Self.writeBuiltInDemo()
        ExtensionInstallStore.add(InstalledExtensionRecord(
            id: Self.demoExtensionID, displayName: "Searxly Demo", directory: dir.path, builtInDemo: true
        ))
        _ = try await load(directory: dir, id: Self.demoExtensionID, grantRequestedHosts: true)
        ExtensionFeatures.laneAEnabled = true
    }

    /// Fully removes an installed extension: unloads it, deletes its package + grants, and (if nothing is
    /// left installed) turns the engine flag back off.
    func uninstall(loadedID id: UUID) {
        guard let entry = loaded.first(where: { $0.id == id }) else { return }
        let extID = entry.extensionID
        unload(entry)
        WebExtensionPermissionStore.clear(id: extID)
        if let record = ExtensionInstallStore.all().first(where: { $0.id == extID }) {
            try? FileManager.default.removeItem(atPath: record.directory)
        }
        ExtensionInstallStore.remove(id: extID)
        if ExtensionInstallStore.all().isEmpty {
            ExtensionFeatures.laneAEnabled = false
        }
    }

    private static func writeBuiltInDemo() throws -> URL {
        let dir = ExtensionInstallStore.extensionsDirectory().appendingPathComponent(demoExtensionID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try demoManifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try demoContent.write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return dir
    }

    private static let demoManifest = """
    {
      "manifest_version": 3,
      "name": "Searxly Demo",
      "version": "1.0",
      "description": "A tiny demo that confirms extensions are working — shows a brief badge on pages you visit.",
      "content_scripts": [
        { "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle" }
      ]
    }
    """

    private static let demoContent = """
    (function () {
      'use strict';
      if (window.top !== window) { return; }   // main frame only
      try {
        var d = document;
        function show() {
          if (d.getElementById('__searxly_demo_badge')) { return; }
          var el = d.createElement('div');
          el.id = '__searxly_demo_badge';
          el.textContent = '✓ Searxly extension active';
          el.style.cssText = 'position:fixed;bottom:16px;right:16px;z-index:2147483647;'
            + 'background:rgba(20,20,22,0.92);color:#fff;'
            + 'font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;'
            + 'padding:8px 12px;border-radius:10px;box-shadow:0 4px 16px rgba(0,0,0,.35);'
            + 'opacity:0;transition:opacity .3s;pointer-events:none';
          (d.body || d.documentElement).appendChild(el);
          requestAnimationFrame(function () { el.style.opacity = '1'; });
          setTimeout(function () {
            el.style.opacity = '0';
            setTimeout(function () { el.remove(); }, 400);
          }, 2500);
        }
        if (d.readyState === 'loading') {
          d.addEventListener('DOMContentLoaded', show, { once: true });
        } else {
          show();
        }
      } catch (e) {}
    })();
    """

    func unload(_ entry: Loaded) {
        try? controller.unload(entry.context)
        loaded.removeAll { $0.id == entry.id }
    }

    func unloadAll() {
        for entry in loaded { try? controller.unload(entry.context) }
        loaded.removeAll()
    }

    // MARK: - Tab registration (for the live BrowserState wiring — next step)

    /// Registers a standard tab's webview so the extension `tabs`/`windows` APIs can see it.
    /// Content-script injection itself only requires the controller attachment in `configure`; this adds
    /// the richer API surface. Called from the browser tab lifecycle once that wiring lands.
    func registerTab(_ webView: WKWebView, active: Bool) {
        // Drop adapters whose webview was deallocated (tab closed / hibernated) so they don't accumulate.
        // (Full chrome.tabs onRemoved events via didCloseTab are Phase 3c — its Swift name is refined and
        // wants a 15.4 runtime to confirm.) The adapters hold the webview weakly, so this is leak-safe.
        tabAdapters = tabAdapters.filter { $0.value.webView != nil }

        let key = ObjectIdentifier(webView)
        if tabAdapters[key] == nil {
            let adapter = WebExtensionTabAdapter(webView: webView, window: window)
            tabAdapters[key] = adapter
            controller.didOpenTab(adapter)
        }
        if active { activeWebView = webView }
    }

    func setActiveTab(_ webView: WKWebView?) {
        activeWebView = webView
        // didActivateTab(_:previousActiveTab:) is NS_REFINED_FOR_SWIFT; left until its Swift signature is
        // confirmed against a 15.4 runtime. The activeTabProvider above already reflects the change.
    }
}

// MARK: - Protocol adapters (production)

/// Wraps a tab's `WKWebView`. `BrowserTab` itself stays untouched — the adapter is the bridge, so the
/// core model carries no WebExtension / macOS 15.4 coupling.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    weak var webView: WKWebView?
    weak var owningWindow: WebExtensionWindowAdapter?

    init(webView: WKWebView, window: WebExtensionWindowAdapter) {
        self.webView = webView
        self.owningWindow = window
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owningWindow }
    func url(for context: WKWebExtensionContext) -> URL? { webView?.url }
    func title(for context: WKWebExtensionContext) -> String? { webView?.title }
}

/// The browser window. Reports the current tabs/active tab via closures the manager wires up.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    var tabsProvider: () -> [any WKWebExtensionTab] = { [] }
    var activeTabProvider: () -> (any WKWebExtensionTab)? = { nil }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabsProvider() }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTabProvider() }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}
