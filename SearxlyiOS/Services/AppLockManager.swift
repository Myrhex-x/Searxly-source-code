//
//  AppLockManager.swift
//  SearxlyiOS
//
//  Face ID / Touch ID app lock — the iOS expression of the macOS AppLockManager (which gates with
//  PIN + security keys; on iOS the platform biometric prompt with passcode fallback is the right
//  gate). Locks on background, re-authenticates on return, and shields content in the app switcher.
//

import Foundation
import LocalAuthentication
import Observation

@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()

    private static let enabledKey = "searxly.ios.appLockEnabled"

    /// Whether the lock is turned on in Settings. Persisted synchronously (never deferred).
    private(set) var isEnabled: Bool

    /// Whether the UI is currently gated. Starts locked when enabled so a cold launch authenticates.
    private(set) var isLocked: Bool

    /// Prevents overlapping biometric prompts (e.g. auto-prompt + manual button tap).
    private var isAuthenticating = false

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled
    }

    /// "Face ID" / "Touch ID" / "Passcode" — for Settings copy and the unlock button.
    var biometryLabel: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return "Passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    /// The device has some owner-authentication mechanism (biometrics or passcode).
    static var deviceSupportsAuthentication: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Re-gate the UI (call when the scene goes to background).
    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// Shows the system authentication prompt; unlocks on success.
    @discardableResult
    func unlock() async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let ok = await Self.authenticate(reason: "Unlock Searxly")
        if ok { isLocked = false }
        return ok
    }

    /// Toggling the lock (either direction) requires passing authentication first — enabling
    /// proves the user CAN unlock (no lockout-by-accident), disabling stops a passerby with an
    /// unlocked phone from quietly turning the gate off.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on != isEnabled else { return true }
        guard Self.deviceSupportsAuthentication else { return false }

        let reason = on ? "Enable App Lock" : "Disable App Lock"
        guard await Self.authenticate(reason: reason) else { return false }

        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { isLocked = false }
        return true
    }

    /// `.deviceOwnerAuthentication` = biometrics with the device passcode as fallback, so a failed
    /// Face ID read never locks the user out of their own browser.
    private static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Public one-shot biometric confirmation for other gated surfaces (e.g. revealing private
    /// tabs). Returns true if the device has no auth configured, so the feature never hard-locks.
    static func confirm(reason: String) async -> Bool {
        guard deviceSupportsAuthentication else { return true }
        return await authenticate(reason: reason)
    }
}
