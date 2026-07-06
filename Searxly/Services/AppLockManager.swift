//
//  AppLockManager.swift
//  Searxly
//
//  App Lock powered by macOS LocalAuthentication (Touch ID + device password fallback).
//  - Replaces the previous custom numeric PIN system.
//  - Optional launch protection + "lock after X minutes of inactivity".
//  - Toggle for "require auth on next launch after quit".
//  - Manual lock + re-auth for sensitive actions (encryption, destructive resets, etc.).
//  - Session auth flag integrates with PrivacyManager / encryption key pre-load (XChat-style).
//  - Legacy PIN data is cleaned up on first load (migration).
//  - Recovery still supported via encryption recovery code when available.
//

import Foundation
import os
import AppKit          // NSEvent (local monitor), NSApplication notifications
import LocalAuthentication
import Security

// PrivacyManager is used for the post-auth encryption key pre-load hook
// (same module — no qualified import needed)

@MainActor
@Observable
final class AppLockManager {
    static let shared = AppLockManager()

    // MARK: - Public State

    /// Whether the App Lock feature is enabled (biometrics / password on launch, inactivity, manual).
    private(set) var isAppLockEnabled: Bool = false

    /// Whether the app is currently unlocked (when the feature is enabled).
    private(set) var isUnlocked: Bool = true

    // MARK: - Inactivity + Quit behavior (new controls)

    /// Minutes of inactivity before automatically locking (0 = Never / disabled).
    /// Default 5 minutes (per user preference in the implementation plan).
    private(set) var inactivityLockMinutes: Int = 5

    /// If true (default), the app will require authentication on the next cold launch after quit.
    /// When false, launches can start unlocked (unless an explicit lock() was performed).
    private(set) var requireOnNextLaunchAfterQuit: Bool = true

    // MARK: - Private

    // NOTE: We keep the *old* enabled key name so existing users who had "Require PIN..." on
    // continue to have the feature on after the migration to biometrics.
    private let enabledKey = "AppLock.PINEnabled"

    private let inactivityMinutesKey = "AppLock.InactivityMinutes"
    private let requireOnQuitKey = "AppLock.RequireOnNextLaunchAfterQuit"
    private let pendingForceLockKey = "AppLock.PendingForceLockOnLaunch"

    // Legacy PIN keychain (only used for one-time migration cleanup)
    private let legacyKeychainService = "com.searxly.applock"
    private let legacyKeychainAccount = "pin-hash"

    private var authorizationInProgress = false

    /// LAContext must stay alive until `evaluatePolicy` finishes; releasing it early can terminate the app.
    private var activeAuthContext: LAContext?

    // Inactivity monitoring (NSEvent + timer). Active only when enabled + minutes > 0 + unlocked.
    private var lastActivityDate = Date()
    private var inactivityTimer: Timer?
    private var eventMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Observers that lock the app + vault the instant the Mac sleeps or the screen locks.
    private var systemLockObservers: [NSObjectProtocol] = []

    private init() {
        loadState()
        // Best-effort: clean any old PIN data the very first time this manager runs.
        cleanupLegacyPINDataIfPresent()
        // Lock immediately on sleep / screen lock (the inactivity timer alone doesn't cover a lid-close).
        setupSystemLockObservers()
    }

    // MARK: - Public API

    func setAppLockEnabled(_ enabled: Bool) {
        guard enabled != isAppLockEnabled else { return }

        isAppLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        // Keep AppData in sync (for encryption of the preference)
        var data = Persistence.load()
        data.appLockEnabled = enabled
        Persistence.save(data)

        if enabled {
            // Do not force isUnlocked = false here. Callers that want the current session
            // to lock immediately (e.g. "test after enabling in Settings") should call lock().
            // Onboarding performs a test auth and keeps the session unlocked for a smooth handoff.
            // Next-launch behavior is driven by requireOnNextLaunchAfterQuit + the pending flag.
            if DeveloperSettings.shared.verboseSecurityLogging {
                Log.security.info("AppLockManager: App Lock enabled (biometrics / password)")
            }
            startOrStopInactivityMonitoring()
        } else {
            isUnlocked = true
            teardownInactivityMonitoring()
            resetSessionAuth()
            if DeveloperSettings.shared.verboseSecurityLogging {
                Log.security.info("AppLockManager: App Lock disabled")
            }
        }
    }

    /// Returns true if the current sensitive action should require biometric re-auth.
    /// This is true when App Lock is enabled AND we haven't yet authenticated this session.
    var requiresAuthenticationForSensitiveActions: Bool {
        isAppLockEnabled && !hasAuthenticatedThisSession
    }

    /// Back-compat alias (some call sites still use the old name during transition).
    var requiresPINForSensitiveActions: Bool { requiresAuthenticationForSensitiveActions }

    /// Convenience: Run the given action only after successful biometric re-auth if required.
    /// If no re-auth is needed (or already authenticated this session), runs immediately.
    ///
    /// The closure is invoked after the system auth sheet completes (success path).
    func performSensitiveAction(_ action: @escaping () -> Void) {
        if !requiresAuthenticationForSensitiveActions {
            action()
            return
        }

        // Fire the system biometric / password prompt.
        authenticateWithBiometrics(reason: "Confirm to continue") { success in
            if success {
                self.markSessionAsAuthenticated()
                action()
            } else {
                // Failure or cancel: do nothing (caller can show its own message if needed).
                if DeveloperSettings.shared.verboseSecurityLogging {
                    Log.security.info("AppLockManager: sensitive action blocked — authentication not completed")
                }
            }
        }
    }

    // MARK: - Session-level authentication for encryption (XChat-style protection)

    /// Whether the user has successfully authenticated (via biometrics/password) in this app session.
    /// When App Lock + Data Encryption are both enabled, this gates access to the encryption key
    /// for the rest of the run (similar to how privacy messengers use a passcode).
    private(set) var hasAuthenticatedThisSession: Bool = false

    /// Call after a successful authentication to mark the session (for encryption pre-load etc.).
    private func markSessionAsAuthenticated() {
        hasAuthenticatedThisSession = true
    }

    /// Resets the session auth flag (called on explicit lock or relevant termination paths).
    private func resetSessionAuth() {
        hasAuthenticatedThisSession = false
    }

    /// Public name kept for any external callers that used the old reset.
    func resetSessionPINUnlock() {
        resetSessionAuth()
    }

    func lock() {
        guard isAppLockEnabled else { return }
        isUnlocked = false
        resetSessionAuth()
        teardownInactivityMonitoring()  // No point monitoring while the lock screen is up
        // Any explicit lock should cause the next launch (if the app is quit while locked) to also require auth.
        UserDefaults.standard.set(true, forKey: pendingForceLockKey)
        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.security.notice("AppLockManager: app locked (manual or inactivity)")
        }
    }

    /// Disables app lock entirely (the modern equivalent of "remove PIN").
    func disableAppLock() {
        isAppLockEnabled = false
        isUnlocked = true
        UserDefaults.standard.set(false, forKey: enabledKey)

        var data = Persistence.load()
        data.appLockEnabled = false
        Persistence.save(data)

        teardownInactivityMonitoring()
        resetSessionAuth()
        // Clean any pending force flag.
        UserDefaults.standard.removeObject(forKey: pendingForceLockKey)
        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.security.notice("AppLockManager: App Lock disabled (removed)")
        }
    }

    /// Legacy name kept during transition so existing call sites (recovery) continue to compile.
    func removePIN() {
        disableAppLock()
    }

    /// Resets app lock state (used by recovery flow with encryption recovery code).
    func resetAllAppLockState() {
        disableAppLock()
        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.security.notice("AppLockManager: all App Lock state reset via recovery")
        }
    }

    // MARK: - Biometric Authentication (LocalAuthentication)

    /// Performs a fresh biometric / device-owner authentication using the system UI.
    /// - reason: Shown to the user in the Touch ID / password prompt.
    /// On success the completion is called with true and the session is marked authenticated.
    /// Safe to call even if the feature is currently "unlocked" (e.g. for re-auth tests).
    func authenticateWithBiometrics(reason: String, completion: @escaping (Bool) -> Void) {
        guard !authorizationInProgress else {
            completion(false)
            return
        }
        authorizationInProgress = true

        let context = LAContext()
        activeAuthContext = context
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password"

        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
            activeAuthContext = nil
            authorizationInProgress = false
            Log.security.error("AppLockManager: biometric auth not available: \(evalError?.localizedDescription ?? "unknown", privacy: .public)")
            completion(false)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.activeAuthContext = nil
                self.authorizationInProgress = false

                if success {
                    // Second factor: when a security key is required for App Lock, biometric success
                    // alone is not enough — also require a tap on an enrolled key before unlocking.
                    Task { @MainActor in
                        let keyOK = await SecurityKeyManager.shared.assertIfRequiredForAppLock()
                        guard keyOK else {
                            // Biometric passed but the security-key step failed / was cancelled → stay locked.
                            if DeveloperSettings.shared.verboseSecurityLogging {
                                Log.security.notice("AppLockManager: biometric ok but security key not provided — staying locked")
                            }
                            completion(false)
                            return
                        }

                        self.isUnlocked = true
                        self.markSessionAsAuthenticated()
                        completion(true)

                        if PrivacyManager.shared.dataEncryptionEnabled {
                            PrivacyManager.shared.onSessionAuthenticatedForEncryption()
                        }
                        self.recordActivity()
                        self.startOrStopInactivityMonitoring()
                        if DeveloperSettings.shared.verboseSecurityLogging {
                            Log.security.info("AppLockManager: authenticated successfully via LocalAuthentication + security key")
                        }
                    }
                } else {
                    if let err = error {
                        Log.security.info("AppLockManager: authentication failed/cancelled: \(err.localizedDescription, privacy: .public)")
                    }
                    completion(false)
                }
            }
        }
    }

    /// Async wrapper (handy for modern call sites).
    func authenticateWithBiometrics(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            authenticateWithBiometrics(reason: reason) { success in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Persistence & Lifecycle

    private func loadState() {
        // Fast launch path: App Lock toggles are mirrored to UserDefaults when changed.
        // Avoid decrypting AppData.json on every cold start when lock is on — that was blocking
        // the main thread before Touch ID could appear.
        isAppLockEnabled = UserDefaults.standard.bool(forKey: enabledKey)

        let udMinutes = UserDefaults.standard.object(forKey: inactivityMinutesKey) as? Int
        inactivityLockMinutes = udMinutes ?? 5

        if let udRequire = UserDefaults.standard.object(forKey: requireOnQuitKey) as? Bool {
            requireOnNextLaunchAfterQuit = udRequire
        } else {
            requireOnNextLaunchAfterQuit = true
        }

        if !isAppLockEnabled {
            let persisted = Persistence.load()
            isAppLockEnabled = persisted.appLockEnabled
            if udMinutes == nil, persisted.appLockInactivityMinutes != 5 {
                inactivityLockMinutes = persisted.appLockInactivityMinutes
            }
            if UserDefaults.standard.object(forKey: requireOnQuitKey) == nil {
                requireOnNextLaunchAfterQuit = persisted.appLockRequireOnNextLaunch
            }
        }

        if inactivityLockMinutes < 0 { inactivityLockMinutes = 0 }
        if inactivityLockMinutes > 60 { inactivityLockMinutes = 60 }

        // Decide initial unlocked state for this launch.
        let pendingForce = UserDefaults.standard.bool(forKey: pendingForceLockKey)
        if isAppLockEnabled {
            if pendingForce {
                isUnlocked = false
                UserDefaults.standard.set(false, forKey: pendingForceLockKey) // consume
            } else {
                // If the user has "require on next launch after quit" OFF, we can start unlocked.
                isUnlocked = !requireOnNextLaunchAfterQuit
            }
        } else {
            isUnlocked = true
        }

        startOrStopInactivityMonitoring()
    }

    /// Called from ContentView on NSApplication.willTerminateNotification.
    /// Sets the pending force flag when appropriate so the next launch respects the user's choice.
    func prepareForTermination() {
        guard isAppLockEnabled else { return }
        if requireOnNextLaunchAfterQuit {
            UserDefaults.standard.set(true, forKey: pendingForceLockKey)
        }
        // If we are currently locked, also force on next launch (user explicitly wanted protection).
        if !isUnlocked {
            UserDefaults.standard.set(true, forKey: pendingForceLockKey)
        }
    }

    // MARK: - System sleep / screen-lock auto-lock

    /// Registers observers that lock the app (and the password vault) the moment the Mac sleeps or the
    /// screen is locked — the "closed the lid / walked away" defense. The inactivity timer alone would
    /// leave things unlocked until it expires; this closes that window.
    private func setupSystemLockObservers() {
        let onEvent: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in AppLockManager.shared.lockForSystemSecurityEvent() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        systemLockObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: onEvent))
        systemLockObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: onEvent))
        // Screen lock (Lock Screen menu, hot corner, ⌃⌘Q, fast user switch) — a system notification.
        systemLockObservers.append(
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: onEvent)
        )
    }

    /// Locks the app (if App Lock is on + currently unlocked) and the password vault (if unlocked) in
    /// response to a system sleep / screen-lock event.
    private func lockForSystemSecurityEvent() {
        if isAppLockEnabled && isUnlocked {
            lock()
            if DeveloperSettings.shared.verboseSecurityLogging {
                Log.security.notice("AppLockManager: locked on system sleep / screen lock")
            }
        }
        // The vault has its own lock, independent of App Lock — don't let it survive a lid-close.
        let vault = PasswordVaultManager.shared
        if vault.isVaultUnlocked {
            vault.lockVault()
        }
    }

    // MARK: - Inactivity Monitoring (timer + NSEvent)

    private func startOrStopInactivityMonitoring() {
        // Only actively monitor for inactivity when the feature is on, a timeout is set,
        // *and* the app is currently unlocked (no point while the lock overlay is showing).
        if isAppLockEnabled && inactivityLockMinutes > 0 && isUnlocked {
            setupInactivityMonitoring()
        } else {
            teardownInactivityMonitoring()
        }
    }

    private func setupInactivityMonitoring() {
        teardownInactivityMonitoring() // clean slate

        lastActivityDate = Date()

        // Local event monitor (fires for this app only). mouseMoved is a bit chatty but perfectly fine for reset.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved, .flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordActivity()
            }
            return event
        }

        // Also reset on the app becoming active again (user came back to the Mac / app).
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordActivity()
            }
        }

        restartInactivityTimer()
        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.security.info("AppLockManager: inactivity monitoring started (\(self.inactivityLockMinutes, privacy: .public) min)")
        }
    }

    private func teardownInactivityMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        if let obs = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            didBecomeActiveObserver = nil
        }
    }

    private func recordActivity() {
        lastActivityDate = Date()
        restartInactivityTimer()
    }

    private func restartInactivityTimer() {
        inactivityTimer?.invalidate()
        guard inactivityLockMinutes > 0 else { return }

        let interval = TimeInterval(inactivityLockMinutes * 60)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            // Timer fires on the main runloop, but be explicit for the compiler's Sendable/actor checking.
            Task { @MainActor [weak self] in
                guard let self = self, self.isAppLockEnabled, self.isUnlocked else { return }
                // Only auto-lock if still past the threshold (defensive).
                if Date().timeIntervalSince(self.lastActivityDate) >= interval {
                    self.lock()
                }
            }
        }
    }

    // MARK: - Legacy PIN Data Cleanup (one-time migration)

    /// If an old PIN hash still lives in the keychain from the previous implementation,
    /// delete it. The enabled flag (same UD key) is intentionally left alone so the
    /// feature stays on for the user — they will just use biometrics going forward.
    private func cleanupLegacyPINDataIfPresent() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            // There was legacy data — remove it.
            SecItemDelete(query as CFDictionary)
            Log.security.info("AppLockManager: legacy PIN keychain item removed (migrated to LocalAuthentication)")
            // Also clean up any old length key that might be lying around.
            UserDefaults.standard.removeObject(forKey: "AppLock.PINLength")
        }
    }

    // MARK: - Helpers for external / debug

    /// Current effective timeout (seconds). 0 means the timer is not active.
    var effectiveInactivityTimeoutSeconds: TimeInterval {
        isAppLockEnabled && inactivityLockMinutes > 0 ? TimeInterval(inactivityLockMinutes * 60) : 0
    }

    /// Setter used by Settings UI. Persists + restarts monitoring if needed.
    /// Also writes to AppData so the preference is encrypted when at-rest encryption is enabled.
    func setInactivityLockMinutes(_ minutes: Int) {
        let clamped = max(0, min(minutes, 60))
        guard clamped != inactivityLockMinutes else { return }
        inactivityLockMinutes = clamped
        UserDefaults.standard.set(clamped, forKey: inactivityMinutesKey)

        // Persist into AppData (encrypted if user has enabled encryption)
        var data = Persistence.load()
        data.appLockInactivityMinutes = clamped
        Persistence.save(data)

        startOrStopInactivityMonitoring()
    }

    /// Setter used by Settings UI.
    func setRequireOnNextLaunchAfterQuit(_ require: Bool) {
        guard require != requireOnNextLaunchAfterQuit else { return }
        requireOnNextLaunchAfterQuit = require
        UserDefaults.standard.set(require, forKey: requireOnQuitKey)

        var data = Persistence.load()
        data.appLockRequireOnNextLaunch = require
        Persistence.save(data)
    }
}
