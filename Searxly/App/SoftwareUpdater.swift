//
//  SoftwareUpdater.swift
//  Searxly
//
//  Sparkle-backed signed auto-updates. Instantiating this (with `startingUpdater: true`) begins
//  automatic background checks against the `SUFeedURL` in Info.plist, and every downloaded update is
//  verified against the bundled `SUPublicEDKey` before it's allowed to install. The matching PRIVATE
//  signing key never ships — it lives only in the developer's login Keychain — so a tampered or
//  MITM'd update is rejected. This is what stops "replace the whole app" supply-chain attacks.
//
//  Gentle reminders: instead of Sparkle interrupting with its own dialog the moment a background check
//  finds an update, we surface a persistent "Update available" control in the sidebar (see
//  `updateAvailable`). The user clicks it when ready → `presentUpdate()` brings Sparkle's install flow
//  into focus. If the gentle-reminder hooks ever don't fire, Sparkle just falls back to its own prompt.
//
//  Privacy: Sparkle's appcast fetch rides its own URLSession — outside PrivacyGate and outside Tor's
//  per-tab SOCKS routing. In Maximum Privacy with native egress blocked (Tor mode always; VPN mode
//  until the tunnel is verified up), an update check would leave from the user's REAL IP and reveal
//  "this IP runs Searxly". So checks follow the same fail-closed rule as every other native fetch:
//  suspended while `PrivacyGate.egressAllowedFast` is false, restored when protection is up.
//

import AppKit
import Foundation
import os
import Sparkle

@MainActor
@Observable
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    /// True once a valid update has been found. Drives the persistent sidebar "Update available" control.
    private(set) var updateAvailable = false
    /// The version string of the found update (for the UI / tooltip).
    private(set) var latestVersion: String?

    private let controller: SPUStandardUpdaterController
    private let bridge: UpdaterBridge
    private var observer: NSObjectProtocol?

    /// Sparkle persists `automaticallyChecksForUpdates` in UserDefaults, so flipping it for the gate
    /// would permanently stomp an explicit user choice. Remember the pre-gate value and whether WE
    /// suspended it, so leaving Maximum Privacy restores exactly what the user had.
    private static let suspendedByGateKey = "Searxly.UpdateChecksSuspendedByPrivacyGate"
    private static let previousAutoChecksKey = "Searxly.UpdateChecksPreviousAutomaticValue"

    /// Searxly Maximum is a SEPARATE product with its own signed release channel. It must NEVER pull the
    /// base app's appcast (`SUFeedURL`) — doing so would offer, and on install replace Maximum with, the
    /// base Searxly build (base icon and all). Maximum's feed lives in `SUFeedURLMaximum` (clearnet) /
    /// `SUFeedURLMaximumOnion` (over Tor). Until that channel is published those keys are blank and
    /// Maximum does not auto-update at all. Set the key later to switch it on — no code change needed.
    static var maximumFeed: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURLMaximum") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
    /// Whether this edition has any feed to check. Base: always. Maximum: only once its own feed is set.
    static var updatesEnabled: Bool { !Edition.isMaximum || maximumFeed != nil }

    private init() {
        bridge = UpdaterBridge()
        controller = SPUStandardUpdaterController(
            // Don't even start the updater on a Maximum build with no dedicated feed — that's what keeps
            // it from touching the base appcast in the background.
            startingUpdater: Self.updatesEnabled,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        if !Self.updatesEnabled { controller.updater.automaticallyChecksForUpdates = false }
        bridge.owner = self

        // Force PrivacyGate's singleton alive so its caches/notifications reflect the persisted mode
        // (its static fast flags default to "allowed" until the instance installs its observers).
        _ = PrivacyGate.shared
        reconcileWithPrivacyGate()

        observer = NotificationCenter.default.addObserver(
            forName: PrivacyGate.protectionStateChangedNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SoftwareUpdater.shared.reconcileWithPrivacyGate()
            }
        }
    }

    /// Called by the delegate bridge when Sparkle finds / stops finding a valid update — and by
    /// TorUpdateChecker when the over-Tor check (Maximum Privacy) finds one, so the same sidebar badge
    /// lights up regardless of which transport discovered the update.
    func setUpdate(available: Bool, version: String?) {
        Log.app.log("SoftwareUpdater.setUpdate available=\(available, privacy: .public) version=\(version ?? "nil", privacy: .public)")
        updateAvailable = available
        if available, let version { latestVersion = version }
        if !available { latestVersion = nil }
    }

    /// True while Maximum Privacy blocks native egress (Tor mode, or VPN mode with the tunnel down).
    private var updateChecksMustPause: Bool {
        PrivacyManager.shared.appPrivacyMode == .maximum && !PrivacyGate.egressAllowedFast
    }

    /// Suspends Sparkle's automatic background checks while Maximum Privacy blocks native egress, and
    /// restores the user's own automatic-check preference once protection is verified up (or the user
    /// leaves Maximum). Safe to call repeatedly.
    private func reconcileWithPrivacyGate() {
        let defaults = UserDefaults.standard
        if updateChecksMustPause {
            if !defaults.bool(forKey: Self.suspendedByGateKey) {
                defaults.set(controller.updater.automaticallyChecksForUpdates, forKey: Self.previousAutoChecksKey)
                defaults.set(true, forKey: Self.suspendedByGateKey)
                Log.privacy.notice("SoftwareUpdater: automatic update checks suspended (Maximum Privacy, protection not covering native egress)")
            }
            controller.updater.automaticallyChecksForUpdates = false
            // Sparkle stays paused. In the Maximum edition ONLY, the update can ride Tor instead — quietly
            // check so the sidebar badge still surfaces new versions. Not done in the base app.
            if Self.updatesEnabled && Edition.isMaximum && PrivacyManager.shared.maxProtection == .tor && TorManager.shared.isRunning {
                Task { await TorUpdateChecker.shared.checkSilently() }
            }
        } else if defaults.bool(forKey: Self.suspendedByGateKey) {
            controller.updater.automaticallyChecksForUpdates = defaults.bool(forKey: Self.previousAutoChecksKey)
            defaults.removeObject(forKey: Self.suspendedByGateKey)
            defaults.removeObject(forKey: Self.previousAutoChecksKey)
            Log.privacy.notice("SoftwareUpdater: automatic update checks restored")
        }
    }

    /// User-initiated check (the "Check for Updates…" menu item) or a tap on the sidebar badge. Blocked
    /// with an explanation while Maximum Privacy has native egress closed — a manual check would leak the
    /// real IP just the same.
    func checkForUpdates() {
        // Maximum with no dedicated feed published yet never checks — and never against the base appcast.
        guard Self.updatesEnabled else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't available yet for Searxly Maximum"
            alert.informativeText = "Searxly Maximum ships on its own separate, signed release channel. Automatic updates arrive with it — this edition never updates from the standard Searxly feed."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        if updateChecksMustPause {
            // Native egress is closed by Maximum Privacy, so Sparkle's own (clearnet) check would leak
            // the real IP. In the Searxly Maximum edition (Tor-only, paid) we can still check + fetch the
            // update over Tor — that's what keeps it updatable. The base app is intentionally left with
            // its original "paused" behaviour: the Tor-routed updater is a Maximum-edition feature only.
            if Edition.isMaximum && PrivacyManager.shared.maxProtection == .tor {
                TorUpdateWindow.show()
            } else {
                // Maximum + VPN with the tunnel not yet up: the VPN, once connected, carries the normal
                // Sparkle check, so just explain the pause.
                let alert = NSAlert()
                alert.messageText = "Update checks are paused by Maximum Privacy"
                alert.informativeText = "Checking now would reveal your real IP address. Connect the Searxly VPN (or leave Maximum Privacy) and checks resume automatically."
                alert.alertStyle = .informational
                alert.runModal()
            }
            return
        }
        controller.updater.checkForUpdates()
    }

    /// Bring the already-found update into focus (from the sidebar control). Same entry point as a manual
    /// check — Sparkle presents the update it discovered.
    func presentUpdate() { checkForUpdates() }

    var canCheckForUpdates: Bool { Self.updatesEnabled && controller.updater.canCheckForUpdates }
}

/// A plain (non-isolated) NSObject that receives Sparkle's delegate callbacks and forwards the relevant
/// ones onto the MainActor updater. Kept separate from `SoftwareUpdater` so the @MainActor class doesn't
/// have to satisfy Sparkle's non-isolated delegate protocols.
private final class UpdaterBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var owner: SoftwareUpdater?
    private let log = Logger(subsystem: "com.myrhex.Searxly", category: "SparkleBridge")

    // MARK: SPUUpdaterDelegate
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Base edition: nil → Sparkle uses SUFeedURL. Maximum: force its own feed so it can never read
        // the base appcast (only reached when a Maximum feed exists and the updater actually started).
        Edition.isMaximum ? SoftwareUpdater.maximumFeed : nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        log.log("Sparkle didFindValidUpdate \(version, privacy: .public)")
        let owner = self.owner
        Task { @MainActor in owner?.setUpdate(available: true, version: version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log.log("Sparkle updaterDidNotFindUpdate")
        let owner = self.owner
        Task { @MainActor in owner?.setUpdate(available: false, version: nil) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log.error("Sparkle didAbortWithError: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders (we show our own sidebar control)
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Don't force Sparkle's popup on a background find — our sidebar badge is the reminder.
        false
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // The user engaged with the update UI — clear the badge.
        let owner = self.owner
        Task { @MainActor in owner?.setUpdate(available: false, version: nil) }
    }
}
