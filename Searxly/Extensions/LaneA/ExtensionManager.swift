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
import AppKit
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
    /// The extension's own icon from its package (nil → callers show a generic placeholder).
    let icon: NSImage?
    /// Plain-language warning when the engine recorded runtime errors for this extension (background
    /// script crashed, unsupported API use, …). nil = healthy. UI shows it instead of pretending
    /// everything is fine.
    let healthWarning: String?
}

/// A 15.0-safe view of an extension's toolbar presence for the header — its browser action (icon,
/// badge, whether it has a popup) plus health. Built from `WKWebExtensionAction` for the active tab.
struct ExtensionHeaderItem: Identifiable {
    let id: String            // extensionID
    let displayName: String
    let icon: NSImage?
    let badgeText: String
    /// True when clicking should open the extension's popup (vs. just firing its action event).
    let presentsPopup: Bool
    let healthWarning: String?
}

extension Notification.Name {
    /// Posted whenever the set of loaded Lane A extensions — or what they may run on — changes
    /// (load, unload, grant, revoke, per-site pause, or a browser-action update). UI surfaces (header
    /// action buttons, settings, globe popover) refresh on it.
    static let laneAExtensionsChanged = Notification.Name("Searxly.LaneAExtensionsChanged")

    /// Posted when the engine asks us to present an extension's action popup programmatically (e.g. a
    /// keyboard command or `action.openPopup()`), carrying the extension id in `object`. The header
    /// opens that extension's popup.
    static let laneAPresentPopupRequested = Notification.Name("Searxly.LaneAPresentPopupRequested")

    /// A tab adapter asked to select (chrome.tabs.update {active:true}) or close (chrome.tabs.remove)
    /// its tab; `object` is the tab's `WKWebView`. The app maps it back to the owning `BrowserTab`.
    static let laneASelectTabByWebView = Notification.Name("Searxly.LaneASelectTabByWebView")
    static let laneACloseTabByWebView = Notification.Name("Searxly.LaneACloseTabByWebView")

    /// chrome.tabs.create with no URL — open a blank new tab.
    static let laneANewTabRequested = Notification.Name("Searxly.LaneANewTabRequested")
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

        // Runtime-error watch: WebKit records engine errors (background script crashed, unsupported
        // API use, …) on the context as they happen. Log each update and nudge the UI so health
        // badges refresh — a broken extension must not silently show as "Active".
        NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let context = note.object as? WKWebExtensionContext {
                    let name = context.webExtension.displayName ?? "extension"
                    if let last = context.errors.last as NSError? {
                        Log.web.warning("[ExtensionManager] \(name, privacy: .public) runtime error #\(context.errors.count, privacy: .public): [\(last.domain, privacy: .public) \(last.code, privacy: .public)] \(last.localizedDescription, privacy: .public)")
                    }
                }
                NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
            }
        }
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
            // API permissions too (storage, scripting, alarms, …) — without them the extension's
            // JS finds `browser.storage` & co. missing and dies at startup. Install = consent to the
            // manifest's requested set, exactly like host access.
            applyPermissionGrants(ext.requestedPermissions, to: context)
            WebExtensionPermissionStore.setGrant(
                WebExtensionGrant(hosts: requestedHosts, permissions: requestedPermissions),
                for: extID
            )
        } else if let recorded = WebExtensionPermissionStore.grant(for: extID) {
            // Re-apply previously approved grants — hosts AND API permissions (the store has always
            // recorded both). Anything not recorded stays denied.
            let patterns = recorded.hosts.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
            applyHostGrants(Set(patterns), to: context)
            applyPermissionGrants(Set(recorded.permissions.map { WKWebExtension.Permission(rawValue: $0) }), to: context)
        }

        // Make the extension's own views (background service worker, popup) inspectable via Web
        // Inspector so their console/errors are debuggable. On in Debug builds and whenever the user
        // has Developer Mode on; off for normal release users.
        #if DEBUG
        context.isInspectable = true
        #else
        context.isInspectable = DeveloperSettings.shared.isEnabled
        #endif

        try controller.load(context)

        // Force the MV3 background service worker to start NOW instead of on-demand. In this WebKit,
        // content scripts and popups that message the background hang if the worker isn't already
        // running — proactively loading it is what makes Dark Reader & co. actually function. No-op if
        // the extension has no background content.
        if ext.hasBackgroundContent {
            context.loadBackgroundContent { error in
                if let error {
                    Log.web.error("[ExtensionManager] \(extID, privacy: .public) background content failed to load: \(String(describing: error), privacy: .public)")
                } else {
                    Log.web.info("[ExtensionManager] \(extID, privacy: .public) background content loaded")
                }
            }
        }

        // Surface what the engine couldn't digest (unsupported manifest keys, bad resources…) — the
        // difference between "extension is broken" and "extension uses APIs WebKit doesn't have".
        for error in ext.errors {
            Log.web.warning("[ExtensionManager] \(ext.displayName ?? extID, privacy: .public) manifest issue: \(error.localizedDescription, privacy: .public)")
        }

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
        Log.web.info("[ExtensionManager] loaded \"\(entry.displayName, privacy: .public)\" — granted \(entry.grantedHostCount, privacy: .public)/\(requestedHosts.count, privacy: .public) host pattern(s), \(context.grantedPermissions.count, privacy: .public)/\(requestedPermissions.count, privacy: .public) API permission(s)")
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
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
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
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

    private func applyPermissionGrants(_ permissions: Set<WKWebExtension.Permission>, to context: WKWebExtensionContext) {
        guard !permissions.isEmpty else { return }
        var grants = context.grantedPermissions
        for permission in permissions { grants[permission] = Date.distantFuture }
        context.grantedPermissions = grants
    }

    /// Grants everything the extension's manifest requests — hosts AND API permissions — and persists
    /// the decision. This is the "user approved the install/permission prompt" path.
    func grantRequestedHosts(for entry: Loaded) {
        applyHostGrants(entry.context.webExtension.allRequestedMatchPatterns, to: entry.context)
        applyPermissionGrants(entry.context.webExtension.requestedPermissions, to: entry.context)
        WebExtensionPermissionStore.setGrant(
            WebExtensionGrant(hosts: entry.requestedHosts, permissions: entry.requestedPermissions),
            for: entry.extensionID
        )
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
    }

    /// Revokes everything granted to the extension and forgets the persisted decision.
    func revokeAll(for entry: Loaded) {
        entry.context.grantedPermissionMatchPatterns = [:]
        entry.context.grantedPermissions = [:]
        WebExtensionPermissionStore.clear(id: entry.extensionID)
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
    }

    // MARK: - UI bridge (availability-unrestricted snapshots + id-based actions)

    /// A 15.0-safe snapshot of every loaded extension, for the approval UI.
    func snapshots() -> [LaneAExtensionSnapshot] {
        loaded.map(snapshot(of:))
    }

    private func snapshot(of entry: Loaded) -> LaneAExtensionSnapshot {
        LaneAExtensionSnapshot(
            id: entry.id,
            extensionID: entry.extensionID,
            displayName: entry.displayName,
            requestedPermissions: entry.requestedPermissions,
            requestedHosts: entry.requestedHosts,
            grantedHostCount: entry.grantedHostCount,
            icon: entry.context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            healthWarning: healthWarning(for: entry)
        )
    }

    /// Plain-language health from the context's recorded runtime errors. A dead background script is
    /// the "installed but nothing happens" case — call it out specifically.
    private func healthWarning(for entry: Loaded) -> String? {
        let errors = entry.context.errors.map { $0 as NSError }
        guard !errors.isEmpty else { return nil }
        if errors.contains(where: {
            $0.domain == WKWebExtensionContext.errorDomain
                && $0.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
        }) {
            return "Its background script failed to start, so most of its features can't run. This extension isn't compatible with Searxly's engine yet."
        }
        return "This extension hit \(errors.count) engine error\(errors.count == 1 ? "" : "s") — some features may not work."
    }

    /// The loaded extensions that are RELEVANT to `url` — their manifest asks to run on this page
    /// (a requested match pattern matches). Includes ones the user has paused on this host, so the
    /// header cluster keeps showing a paused extension (as "Paused") instead of making it vanish the
    /// instant you toggle it off. Per-site pause state is read separately by the UI (ExtensionSiteStore).
    func extensionsForPage(_ url: URL) -> [LaneAExtensionSnapshot] {
        loaded.filter { entry in
            entry.context.webExtension.allRequestedMatchPatterns.contains { $0.matches(url) }
        }.map(snapshot(of:))
    }

    // MARK: - Browser actions (toolbar buttons + popups)

    /// The extensions to surface as header buttons for the given tab: those with a clickable popup
    /// (Bitwarden, uBlock Origin Lite, Dark Reader, …) OR that run on the current page. Popup-capable
    /// ones always appear (like Chrome's pinned icons) so they're reachable everywhere.
    func headerItems(for webView: WKWebView?) -> [ExtensionHeaderItem] {
        guard let webView else { return [] }
        let adapter = ensureAdapter(for: webView)
        let url = webView.url
        return loaded.compactMap { entry -> ExtensionHeaderItem? in
            let action = entry.context.action(for: adapter)
            let presents = action?.presentsPopup ?? false
            let relevant = url.map { u in
                entry.context.webExtension.allRequestedMatchPatterns.contains { $0.matches(u) }
            } ?? false
            guard presents || relevant else { return nil }
            let icon = action?.icon(for: CGSize(width: 32, height: 32))
                ?? entry.context.webExtension.icon(for: CGSize(width: 32, height: 32))
            return ExtensionHeaderItem(
                id: entry.extensionID,
                displayName: (action?.label).flatMap { $0.isEmpty ? nil : $0 } ?? entry.displayName,
                icon: icon,
                badgeText: action?.badgeText ?? "",
                presentsPopup: presents,
                healthWarning: healthWarning(for: entry)
            )
        }
    }

    /// Anchor + target for a popup the header asked to open, consumed by the controller delegate's
    /// `presentActionPopup` so it can show the engine's own `popupPopover` (which comes with its
    /// messaging wired to the background — the reason we don't host `popupWebView` ourselves).
    private weak var pendingPopoverAnchor: NSView?
    private var pendingPopoverID: String?
    /// A stable header anchor for engine-initiated popups (keyboard commands) that have no click site.
    weak var fallbackPopoverAnchor: NSView?

    /// The user clicked an extension's toolbar button. Performs the action; if it has a popup, the
    /// engine calls back into `presentActionPopup`, which shows the popup anchored to `anchor`.
    func activateAction(extensionID: String, for webView: WKWebView, relativeTo anchor: NSView) {
        guard let entry = loaded.first(where: { $0.extensionID == extensionID }) else { return }
        let adapter = ensureAdapter(for: webView)
        setActive(adapter, webView: webView)      // popup queries need the right active tab
        pendingPopoverAnchor = anchor
        pendingPopoverID = extensionID
        // Wake the background service worker BEFORE the popup connects to it. MV3 workers suspend when
        // idle, and a popup that connects to a suspended worker hangs on "Loading" — so ensure it's
        // running first, then perform the action (which triggers the popup presentation).
        let context = entry.context
        context.loadBackgroundContent { _ in
            context.performAction(for: adapter)
        }
    }

    /// Called by the delegate when the engine wants to present `extensionID`'s popup. Returns the
    /// anchor only when the user actually clicked this extension's button — so the engine can't
    /// auto-present a popup on its own (which showed up as a stray popup on launch).
    func takePopoverAnchor(for extensionID: String) -> NSView? {
        guard pendingPopoverID == extensionID else { return nil }
        defer { pendingPopoverAnchor = nil; pendingPopoverID = nil }
        return pendingPopoverAnchor
    }

    /// Whether an extension's action shows a popup (vs. dispatching an onClicked event).
    func actionPresentsPopup(extensionID: String, for webView: WKWebView) -> Bool {
        guard let entry = loaded.first(where: { $0.extensionID == extensionID }) else { return false }
        return entry.context.action(for: ensureAdapter(for: webView))?.presentsPopup ?? false
    }

    func closePopup(extensionID: String, for webView: WKWebView) {
        guard let entry = loaded.first(where: { $0.extensionID == extensionID }) else { return }
        entry.context.action(for: ensureAdapter(for: webView))?.closePopup()
    }

    /// The extension's options page URL, if it declares one (chrome.runtime.openOptionsPage / the
    /// "Extension options" affordance). Opened as a normal tab.
    func optionsPageURL(extensionID: String) -> URL? {
        loaded.first(where: { $0.extensionID == extensionID })?.context.optionsPageURL
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

    /// Uninstall by stable extension id (what the header/settings surfaces carry).
    func uninstall(extensionID: String) {
        guard let entry = loaded.first(where: { $0.extensionID == extensionID }) else { return }
        uninstall(loadedID: entry.id)
    }

    // MARK: - Install / reload / uninstall (normal-user, persistent)

    static let demoExtensionID = "searxly.demo"

    /// Reloads every installed extension from `ExtensionInstallStore` (applies persisted grants;
    /// default-deny for anything not previously approved). Called once at launch via `ExtensionBootstrap`.
    func reloadInstalled() async {
        for record in ExtensionInstallStore.all() {
            // The resource is either a directory (built-in demo) or a `.zip` package (store installs) —
            // WKWebExtension accepts both. Just check the path still exists.
            let resource = URL(fileURLWithPath: record.directory)
            guard FileManager.default.fileExists(atPath: resource.path) else {
                Log.web.error("[ExtensionManager] installed package missing on disk: \(record.id, privacy: .public) at \(record.directory, privacy: .public)")
                continue
            }
            do {
                _ = try await load(directory: resource, id: record.id)
            } catch {
                Log.web.error("[ExtensionManager] relaunch load failed for \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One-shot Chrome Web Store install (the marketplace's paste field + Popular cards, where the
    /// card itself is the consent surface): fetch + confirm in a single call.
    @discardableResult
    func installFromChromeWebStore(_ input: String) async throws -> Loaded {
        let pending = try await fetchFromChromeWebStore(input)
        return try await confirmStoreInstall(pending)
    }

    /// Step 1 of the in-browser "Add to Searxly" flow: downloads the `.crx` from Google's packaging
    /// endpoint, verifies the CRX3 signature binds the package to that exact extension ID, stages the
    /// embedded ZIP on disk, and reads the metadata the permission prompt needs. Nothing is loaded and
    /// nothing is granted yet — the user hasn't consented.
    func fetchFromChromeWebStore(_ input: String) async throws -> PendingStoreInstall {
        guard let id = ChromeWebStore.extensionID(from: input) else {
            Log.web.error("[ExtensionManager] store install: unrecognized input")
            throw ChromeWebStoreError.invalidInput
        }
        let crx: Data
        do {
            crx = try await ChromeWebStore.download(id: id)
        } catch {
            Log.web.error("[ExtensionManager] store download failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        let package: CRX3Package
        do {
            package = try CRX3.parse(crx, expectedID: id)
        } catch {
            Log.web.error("[ExtensionManager] CRX verify failed for \(id, privacy: .public) (\(crx.count, privacy: .public) bytes): \(String(describing: error), privacy: .public)")
            throw error
        }

        let staged = ExtensionInstallStore.extensionsDirectory()
            .appendingPathComponent("staging-\(id).zip")
        try package.zipData.write(to: staged, options: [.atomic])
        do {
            // Instantiating WKWebExtension parses the manifest without loading anything into the
            // controller — exactly what the prompt needs.
            let ext = try await WKWebExtension(resourceBaseURL: staged)
            return PendingStoreInstall(
                id: id,
                displayName: ext.displayName ?? (ext.manifest["name"] as? String) ?? id,
                requestedPermissions: ext.requestedPermissions.map { $0.rawValue },
                requestedHosts: ext.allRequestedMatchPatterns.map { $0.string },
                stagedPackage: staged
            )
        } catch {
            Log.web.error("[ExtensionManager] WKWebExtension rejected the staged package for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Step 2 — the user approved the permission prompt. Moves the staged package into place, loads
    /// it, grants the hosts it requests (the consent just given), and turns the engine on. Confirming
    /// over an existing install replaces it (the update path); WebKit-side extension storage survives
    /// because it's keyed by `context.uniqueIdentifier` (the extension ID).
    @discardableResult
    func confirmStoreInstall(_ pending: PendingStoreInstall) async throws -> Loaded {
        if let existing = loaded.first(where: { $0.extensionID == pending.id }) { unload(existing) }

        let dir = ExtensionInstallStore.extensionsDirectory()
            .appendingPathComponent(pending.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = dir.appendingPathComponent("package.zip")
        try FileManager.default.moveItem(at: pending.stagedPackage, to: pkg)

        do {
            let entry = try await load(directory: pkg, id: pending.id, grantRequestedHosts: true)
            ExtensionInstallStore.add(InstalledExtensionRecord(
                id: pending.id, displayName: entry.displayName, directory: pkg.path, builtInDemo: false
            ))
            ExtensionFeatures.laneAEnabled = true
            return entry
        } catch {
            Log.web.error("[ExtensionManager] load-after-confirm failed for \(pending.id, privacy: .public): \(String(describing: error), privacy: .public)")
            // Don't leave a broken package recorded or on disk.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Step 2, the other branch — the user declined. Removes the staged package; nothing was granted.
    func cancelStoreInstall(_ pending: PendingStoreInstall) {
        try? FileManager.default.removeItem(at: pending.stagedPackage)
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
        NotificationCenter.default.post(name: .laneAExtensionsChanged, object: nil)
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
        let adapter = ensureAdapter(for: webView)
        if active { setActive(adapter, webView: webView) }
    }

    /// Returns the adapter for a webview, creating + announcing it (`didOpenTab`) on first sight, and
    /// pruning adapters whose webview has deallocated so they don't accumulate.
    @discardableResult
    private func ensureAdapter(for webView: WKWebView) -> WebExtensionTabAdapter {
        for (key, adapter) in tabAdapters where adapter.webView == nil {
            controller.didCloseTab(adapter, windowIsClosing: false)
            tabAdapters[key] = nil
        }
        let key = ObjectIdentifier(webView)
        if let adapter = tabAdapters[key] { return adapter }
        let adapter = WebExtensionTabAdapter(webView: webView, window: window)
        tabAdapters[key] = adapter
        controller.didOpenTab(adapter)
        return adapter
    }

    /// The active-tab hook: call when the selected standard tab changes so extensions get
    /// `chrome.tabs.onActivated`. Fires `didActivateTab` with the previous active tab.
    func setActiveTab(_ webView: WKWebView?) {
        guard let webView else {
            activeWebView = nil
            return
        }
        setActive(ensureAdapter(for: webView), webView: webView)
    }

    private func setActive(_ adapter: WebExtensionTabAdapter, webView: WKWebView) {
        let previous = activeWebView.flatMap { tabAdapters[ObjectIdentifier($0)] }
        activeWebView = webView
        if ObjectIdentifier(adapter) != previous.map(ObjectIdentifier.init) {
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
    }

    /// A standard tab closed: tell the extension engine so `chrome.tabs.onRemoved` fires.
    func tabClosed(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let adapter = tabAdapters[key] else { return }
        controller.didCloseTab(adapter, windowIsClosing: false)
        tabAdapters[key] = nil
        if activeWebView === webView { activeWebView = nil }
    }
}

// MARK: - Protocol adapters (production)

/// Wraps a tab's `WKWebView`. `BrowserTab` itself stays untouched — the adapter is the bridge, so the
/// core model carries no WebExtension / macOS 15.4 coupling. Tab mutations that need the browser (select,
/// close) post notifications the app maps back to the owning `BrowserTab`; navigation acts on the webview
/// directly.
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

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        let tabs = owningWindow?.tabsProvider() ?? []
        return tabs.firstIndex { ($0 as? WebExtensionTabAdapter) === self } ?? 0
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        (owningWindow?.activeTabProvider() as? WebExtensionTabAdapter) === self
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(webView?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.frame.size ?? .zero
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let webView { NotificationCenter.default.post(name: .laneASelectTabByWebView, object: webView) }
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if selected, let webView { NotificationCenter.default.post(name: .laneASelectTabByWebView, object: webView) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let webView { NotificationCenter.default.post(name: .laneACloseTabByWebView, object: webView) }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.load(URLRequest(url: url))
        completionHandler(nil)
    }
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
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
