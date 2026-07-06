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

    private init() {
        bridge = UpdaterBridge()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
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

    /// Called by the delegate bridge when Sparkle finds / stops finding a valid update.
    fileprivate func setUpdate(available: Bool, version: String?) {
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
        guard !updateChecksMustPause else {
            let alert = NSAlert()
            alert.messageText = "Update checks are paused by Maximum Privacy"
            alert.informativeText = "Update checks don't travel through Tor, so checking now would reveal your real IP address. They resume automatically when your protection covers them — switch protection to the Searxly VPN (and connect), or leave Maximum Privacy, to check for updates."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        controller.updater.checkForUpdates()
    }

    /// Bring the already-found update into focus (from the sidebar control). Same entry point as a manual
    /// check — Sparkle presents the update it discovered.
    func presentUpdate() { checkForUpdates() }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
}

/// A plain (non-isolated) NSObject that receives Sparkle's delegate callbacks and forwards the relevant
/// ones onto the MainActor updater. Kept separate from `SoftwareUpdater` so the @MainActor class doesn't
/// have to satisfy Sparkle's non-isolated delegate protocols.
private final class UpdaterBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var owner: SoftwareUpdater?
    private let log = Logger(subsystem: "com.myrhex.Searxly", category: "SparkleBridge")

    // MARK: SPUUpdaterDelegate
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
