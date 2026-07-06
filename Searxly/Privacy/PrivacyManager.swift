//
//  PrivacyManager.swift
//  Searxly
//
//  Focused, single-responsibility manager for all privacy-related data clearing
//  and history recording decisions. Keeps SettingsView and ContentView (now thin, state in BrowserState) small
//  and prevents logic duplication / big bugs from piling into one file.
//
//  (Smart suggestions / learned data removed from the address bar)
//  - Clear history / bookmarks (delegates to Persistence)
//  - Clear Standard Tab Website Data (WKWebsiteDataStore for persistent tabs)
//  - Future: coordination via NotificationCenter so active views can refresh
//

import AppKit
import Foundation
import os
import LocalAuthentication
import UniformTypeIdentifiers
import WebKit
import SwiftUI

// AppLockManager provides optional biometric (LocalAuthentication) app lock.
// The session auth flag is used to gate encryption key access this run (defense in depth).
// (Same module — no qualified import needed)

@MainActor
@Observable
final class PrivacyManager {
    static let shared = PrivacyManager()

    // Notification names for loose coupling (views listen instead of direct references)
    static let historyClearedNotification = Notification.Name("Searxly.HistoryCleared")
    static let standardWebDataClearedNotification = Notification.Name("Searxly.StandardWebDataCleared")
    static let allPrivacyDataClearedNotification = Notification.Name("Searxly.AllPrivacyDataCleared")

    // Note: historyEnabledKey is kept only for one-time migration reference.
    // The canonical value now lives inside AppData.json and is managed here.
    static let historyEnabledKey = "Searxly.HistoryEnabled" // legacy only

    /// Current value (source of truth after migration). Updated via setHistoryEnabled.
    private(set) var historyEnabled: Bool = false

    /// Whether "New Tab" (⌘T) should create Private (ephemeral) tabs by default.
    /// "New Private Tab" (⌘⇧T) always forces private regardless.
    private(set) var defaultNewTabsToPrivate: Bool = true

    /// Whether local data (AppData.json) should be encrypted at rest using CryptoKit + Keychain.
    private(set) var dataEncryptionEnabled: Bool = false

    /// App-wide privacy posture (Normal / Encrypted / Maximum). Maximum engages the fail-closed kill
    /// switch (PrivacyGate) and the Strict fingerprint cluster injected by WebViewFactory. Both of
    /// those read this value at runtime, so toggling the mode is what turns them on/off.
    private(set) var appPrivacyMode: AppPrivacyMode = .normal

    /// Which network Maximum Privacy enforces (Searxly VPN or Tor). Only meaningful in .maximum.
    private(set) var maxProtection: MaxProtection = .tor

    /// Posted (main thread) whenever appPrivacyMode changes, so open tabs can refresh their webviews
    /// and pick up per-mode script/UA injection. Observed by BrowserState / TabCoordinator.
    static let appPrivacyModeChangedNotification = Notification.Name("Searxly.AppPrivacyModeChanged")

    /// Posted when the Maximum-Privacy protection network choice (VPN ↔ Tor) changes, so PrivacyGate
    /// can bring the newly chosen network up and re-route the local SearXNG's upstream traffic.
    static let maxProtectionChangedNotification = Notification.Name("Searxly.MaxProtectionChanged")

    private init() {
        // Ensure any old UserDefaults value has been moved into the JSON.
        Persistence.migrateHistoryEnabledIfNeeded()
        Persistence.migrateDefaultTabPrivacyIfNeeded()

        // Load the canonical values (privacy-first defaults on fresh installs).
        let persistedData = Persistence.load()
        historyEnabled = persistedData.historyEnabled
        defaultNewTabsToPrivate = persistedData.defaultNewTabsToPrivate
        appPrivacyMode = persistedData.appPrivacyMode
        maxProtection = persistedData.maxProtection

        // Load encryption preference (stored in a small metadata key for now).
        dataEncryptionEnabled = EncryptedDataStore.isEncryptionEnabled()
    }

    // MARK: - Fresh install bootstrap (privacy-first defaults)

    private static let freshInstallDefaultsKey = "Searxly.FreshInstallPrivacyDefaultsApplied"

    /// Applies privacy-first defaults on the very first launch (no existing AppData.json).
    /// Existing/upgrading users are untouched.
    @MainActor
    static func applyFreshInstallDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: freshInstallDefaultsKey) else { return }

        let appDataURL = Persistence.appDataFileURL()
        guard !FileManager.default.fileExists(atPath: appDataURL.path) else {
            UserDefaults.standard.set(true, forKey: freshInstallDefaultsKey)
            return
        }

        UserDefaults.standard.set(true, forKey: freshInstallDefaultsKey)

        let context = LAContext()
        let deviceAuthAvailable = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)

        var data = AppData()
        data.historyEnabled = false
        data.defaultNewTabsToPrivate = true
        data.appLockEnabled = deviceAuthAvailable
        Persistence.save(data)

        let manager = PrivacyManager.shared
        manager.setHistoryEnabled(false)
        manager.setDefaultNewTabsToPrivate(true)
        manager.setDataEncryptionEnabled(true)

        if deviceAuthAvailable {
            AppLockManager.shared.setAppLockEnabled(true)
        }

        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.privacy.info("PrivacyManager: fresh install defaults applied (history off, encryption on, private tabs default, app lock: \(deviceAuthAvailable, privacy: .public))")
        }
    }

    // MARK: - History Recording Decision (called from ContentView before appending)

    /// Returns whether new browsing history entries should be recorded right now.
    static func shouldRecordHistory() -> Bool {
        return shared.historyEnabled
    }

    /// Updates the preference, persists it atomically via Persistence, and keeps in-memory value in sync.
    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled != historyEnabled else { return }

        historyEnabled = enabled
        Persistence.setHistoryEnabled(enabled)
    }

    /// Setter for the default new tab privacy mode.
    func setDefaultNewTabsToPrivate(_ enabled: Bool) {
        guard enabled != defaultNewTabsToPrivate else { return }

        defaultNewTabsToPrivate = enabled

        Persistence.setDefaultNewTabsToPrivate(enabled)
    }

    // MARK: - App Privacy Mode (Normal / Encrypted / Maximum ladder)

    /// Sets the app-wide privacy mode and applies the corresponding posture.
    ///
    /// Ladder (each rung is a superset of the one below):
    ///   - `.normal`    → no extra hardening (the always-on Tier-1 in WebViewFactory still applies).
    ///   - `.encrypted` → local at-rest lockdown via `enableSecureMacPreset()`.
    ///   - `.maximum`   → encrypted lockdown PLUS strict web privacy (`enableStrictPrivacyMode()`).
    ///                    The fail-closed kill switch (PrivacyGate) and the Strict fingerprint cluster
    ///                    (WebViewFactory) read `appPrivacyMode` at runtime, so they engage automatically.
    ///
    /// Note: moving DOWN a rung never auto-disables at-rest encryption or App Lock — undoing those is
    /// potentially destructive (decrypting data) and is left to the explicit encryption controls. A
    /// lower mode only disengages the web-layer protections (kill switch + farbling), which are keyed
    /// off this value at read time. Posts `appPrivacyModeChangedNotification` so tabs refresh.
    func setAppPrivacyMode(_ mode: AppPrivacyMode) {
        guard mode != appPrivacyMode else { return }
        switch mode {
        case .normal:
            break
        case .encrypted:
            enableSecureMacPreset()
        case .maximum:
            enableSecureMacPreset()
            enableStrictPrivacyMode()
        }
        markAppPrivacyMode(mode)
    }

    /// Records the persistent mode and engages the kill switch / fingerprint farbling / header pill
    /// WITHOUT applying the ladder presets — for callers (e.g. onboarding) that already applied their
    /// own hardening (possibly with different options, like App Lock off). Posts the change notification
    /// so open tabs rebuild and PrivacyGate updates.
    func markAppPrivacyMode(_ mode: AppPrivacyMode) {
        guard mode != appPrivacyMode else { return }
        appPrivacyMode = mode
        Persistence.setAppPrivacyMode(mode)
        NotificationCenter.default.post(name: Self.appPrivacyModeChangedNotification, object: nil)
        Log.privacy.info("PrivacyManager: appPrivacyMode set to \(mode.rawValue, privacy: .public)")
    }

    /// Sets which network Maximum Privacy enforces (Searxly VPN or Tor) and persists it.
    func setMaxProtection(_ protection: MaxProtection) {
        guard protection != maxProtection else { return }
        maxProtection = protection
        Persistence.setMaxProtection(protection)
        NotificationCenter.default.post(name: Self.maxProtectionChangedNotification, object: nil)
        Log.privacy.info("PrivacyManager: maxProtection set to \(protection.rawValue, privacy: .public)")
    }

    /// Helper used by "New Tab" command: returns the mode the user wants for regular new tabs.
    static func preferredNewTabMode() -> TabPrivacyMode {
        return shared.defaultNewTabsToPrivate ? .privateEphemeral : .standard
    }

    /// Enables or disables encryption of local AppData.
    /// This method handles the migration (re-encrypt or decrypt current data) with improved robustness.
    func setDataEncryptionEnabled(_ enabled: Bool) {
        guard enabled != dataEncryptionEnabled else { return }

        _performSetDataEncryptionEnabled(enabled)
    }

    /// Internal direct setter used by backup restore and other privileged paths.
    func forceSetDataEncryptionEnabled(_ enabled: Bool) {
        guard enabled != dataEncryptionEnabled else { return }
        _performSetDataEncryptionEnabled(enabled)
    }

    private func _performSetDataEncryptionEnabled(_ enabled: Bool) {
        let previousState = dataEncryptionEnabled
        dataEncryptionEnabled = enabled
        EncryptedDataStore.setEncryptionEnabled(enabled)

        if enabled && !previousState {
            // Turning encryption ON
            if !KeychainManager.keyExists() {
                let newKey = DataEncryptor.generateKey()
                let saved = KeychainManager.saveKey(newKey)
                if !saved {
                    Log.security.error("PrivacyManager: CRITICAL — failed to save new encryption key to Keychain; disabling encryption to avoid unrecoverable writes")
                    // Revert the flag to avoid leaving the user in a broken state
                    dataEncryptionEnabled = false
                    EncryptedDataStore.setEncryptionEnabled(false)
                    return
                }
                Log.security.notice("PrivacyManager: generated and stored new encryption key for first-time encryption")
            } else {
                Log.security.info("PrivacyManager: using existing encryption key")
            }

            // Force a re-save. EncryptedDataStore will now encrypt because the flag is set.
            let currentData = Persistence.load()
            Persistence.save(currentData)
            Log.security.info("PrivacyManager: existing data re-saved in encrypted form")

        } else if !enabled && previousState {
            // Turning encryption OFF — decrypt by forcing a plaintext save.
            let currentData = Persistence.load()
            Persistence.save(currentData)
            // Phase 2 Policy: When turning encryption OFF, we keep the key by default.
            // This allows the user to easily re-enable encryption later without data loss
            // (old encrypted backups would still be decryptable).
            // The user can explicitly delete the key later if they want (via future recovery UI).
            Log.security.notice("PrivacyManager: data encryption disabled; data written as plaintext, key retained (Phase 2 policy)")
        }

        Log.security.info("PrivacyManager: data encryption set to \(enabled, privacy: .public)")
    }

    /// Explicitly deletes the encryption key from the Keychain.
    /// Should only be called after user confirmation (especially when encryption is currently enabled).
    func deleteEncryptionKey() {
        let deleted = KeychainManager.deleteKey()
        Log.security.notice("PrivacyManager: encryption key deletion requested (success: \(deleted, privacy: .public))")
    }

    // MARK: - App Lock + Encryption Integration (session-level unlock)

    /// Called by AppLockManager after successful biometric/password authentication when encryption is enabled.
    /// This allows the app-level auth to act as an additional gate for the encryption key
    /// (XChat / Signal style passcode protection).
    func onSessionAuthenticatedForEncryption() {
        // Proactively load the encryption key into memory for this session.
        // This surfaces the Keychain .userPresence prompt (if needed) right after the user
        // authenticates for App Lock, rather than at some random later moment.
        if dataEncryptionEnabled, KeychainManager.keyExists() {
            _ = KeychainManager.loadKey()
            if DeveloperSettings.shared.verboseSecurityLogging {
                Log.security.info("PrivacyManager: encryption key pre-loaded after App Lock authentication")
            }
        }
    }

    // MARK: - Secure Mac Preset (encryption + App Lock + recovery + no history)

    struct SecureMacPresetResult: Equatable {
        var historyDisabled: Bool = false
        var encryptionEnabled: Bool = false
        var appLockEnabled: Bool = false
        var recoveryCode: String?
        var partialError: String?
    }

    /// One-shot "Secure this Mac" preset for onboarding and Settings.
    /// - Disables browsing history
    /// - Enables at-rest encryption (CryptoKit + Keychain)
    /// - Enables App Lock (when `enableAppLock` is true)
    /// - Returns the recovery code so the UI can copy or save it
    @discardableResult
    func enableSecureMacPreset(enableAppLock: Bool = true) -> SecureMacPresetResult {
        var result = SecureMacPresetResult()

        setHistoryEnabled(false)
        result.historyDisabled = !historyEnabled

        if !dataEncryptionEnabled {
            setDataEncryptionEnabled(true)
        }
        result.encryptionEnabled = dataEncryptionEnabled

        if enableAppLock {
            if !AppLockManager.shared.isAppLockEnabled {
                AppLockManager.shared.setAppLockEnabled(true)
            }
            result.appLockEnabled = AppLockManager.shared.isAppLockEnabled
        } else {
            result.appLockEnabled = AppLockManager.shared.isAppLockEnabled
        }

        result.recoveryCode = exportEncryptionRecoveryCode()

        if !result.encryptionEnabled {
            result.partialError = "Encryption could not be enabled. Searxly may not have Keychain access."
        } else if result.recoveryCode == nil {
            result.partialError = "Encryption is on, but the recovery code could not be exported."
        } else if enableAppLock && !result.appLockEnabled {
            result.partialError = "History is off and data is encrypted, but App Lock could not be enabled."
        }

        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.privacy.info("PrivacyManager: Secure Mac preset applied (history off: \(result.historyDisabled, privacy: .public), encryption: \(result.encryptionEnabled, privacy: .public), app lock: \(result.appLockEnabled, privacy: .public), recovery: \(result.recoveryCode != nil, privacy: .public))")
        }

        return result
    }

    /// Copies the encryption recovery code to the pasteboard. Routed through the vault's
    /// clipboard manager so the code is marked concealed (skipped by clipboard history /
    /// Universal Clipboard) and auto-clears after its 45-second window.
    @discardableResult
    func copyEncryptionRecoveryCodeToClipboard() -> Bool {
        guard let code = exportEncryptionRecoveryCode() else { return false }
        VaultClipboardManager.shared.copySensitive(code)
        return true
    }

    // MARK: - Strict / Maximum Privacy Preset

    /// Applies the recommended **Maximum Privacy** preset (browsing-session protection).
    /// - Forces all new ⌘T tabs to be Private
    /// - Disables history recording
    /// - Optionally clears standard web data (cookies etc.)
    /// - Disables Local AI and clears transient AI state
    ///
    /// For disk-level protection (encryption + App Lock + recovery code), use `enableSecureMacPreset()`.
    func enableStrictPrivacyMode(clearWebData: Bool = true) {
        setDefaultNewTabsToPrivate(true)
        setHistoryEnabled(false)

        if clearWebData {
            clearStandardWebData()
        }

        // Phase 0+: also force-disable Local AI features and clear any transient synthesis/chat state.
        // Users who want "Maximum Privacy" should not have on-device AI running.
        // Also clear any (possibly permanently saved) Local AI chat transcript.
        LocalIntelligenceManager.shared.isEnabled = false
        Task { await LocalIntelligenceManager.shared.unloadAll() }
        LocalIntelligenceManager.shared.clearCurrentChatTranscript()
        NotificationCenter.default.post(name: Notification.Name("Searxly.LocalAIClearRequested"), object: nil)

        if DeveloperSettings.shared.verboseSecurityLogging {
            Log.privacy.info("PrivacyManager: Strict/Maximum Privacy mode enabled (private tabs default + history off + Local AI disabled)")
        }
    }

    /// Refreshes the in-memory encryption flag from on-disk metadata after recovery or restore.
    func syncEncryptionStateFromDisk() {
        dataEncryptionEnabled = EncryptedDataStore.isEncryptionEnabled()
    }

    /// Returns a base64 recovery code for the current encryption key (if one exists).
    /// Read from the Keychain on demand every time — we deliberately keep no long-lived
    /// String copy of key material in the heap.
    func exportEncryptionRecoveryCode() -> String? {
        return KeychainManager.exportKeyAsRecoveryCode()
    }

    /// Presents a save panel (sheet on the key window when possible) and writes the recovery code.
    @discardableResult
    func saveRecoveryCodeToFile(_ code: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.title = "Save Searxly Recovery Code"
            panel.nameFieldStringValue = "Searxly-Recovery-Code.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.prompt = "Save"

            NSApp.activate(ignoringOtherApps: true)

            let parentWindow = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })

            if let parentWindow {
                panel.beginSheetModal(for: parentWindow) { response in
                    if response == .OK, let url = panel.url {
                        continuation.resume(returning: Self.writeRecoveryCodeContent(code, to: url))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } else {
                let response = panel.runModal()
                if response == .OK, let url = panel.url {
                    continuation.resume(returning: Self.writeRecoveryCodeContent(code, to: url))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func writeRecoveryCodeContent(_ code: String, to url: URL) -> URL? {
        let content = """
        Searxly Encryption Recovery Code
        =================================

        Generated: \(Date().formatted(date: .abbreviated, time: .shortened))

        IMPORTANT: Store this file somewhere safe. Anyone with this code can decrypt
        your Searxly data (history, bookmarks, tabs, and instances).

        Recovery code:
        \(code)
        """

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            // Owner-only permissions — this file is the decryption key for all local data.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            Log.privacy.error("PrivacyManager: failed to save recovery code file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Panic Wipe (Emergency Clear Everything)

    /// Nuclear option. Wipes as much local sensitive data as possible in one action.
    /// Intended for "someone is looking over my shoulder / I need to nuke everything right now" situations.
    ///
    /// - Clears history, bookmarks, and the persisted tab session (open tabs)
    /// - Clears VPN profiles (which may contain private keys from user configs)
    /// - Clears the password vault and vault lock data
    /// - Clears all standard web data (cookies, storage, caches)
    /// - Rotates (or deletes) the at-rest encryption key so previously copied encrypted data
    ///   can no longer be decrypted with what remains in this Mac's Keychain
    /// - If requested, also stops the local native SearXNG process
    /// - Also disables Local AI and clears any transient AI context / synthesis (Phase 0+)
    ///
    /// Deliberately NOT wiped: the wallet seed. Destroying it could permanently lose funds;
    /// it has its own PIN/keychain protection and its own explicit delete flow in wallet settings.
    ///
    /// This is deliberately loud and destructive.
    func panicWipe(stopLocalSearxng: Bool = true, completion: (() -> Void)? = nil) {
        _performPanicWipe(stopLocalSearxng: stopLocalSearxng, completion: completion)
    }

    private func _performPanicWipe(stopLocalSearxng: Bool, completion: (() -> Void)?) {
        clearHistory()
        clearBookmarks()

        // Search-query suggestions live in their own store (UserDefaults, separate from browsing
        // history) — clear them too so a wipe genuinely leaves no search terms behind.
        SearchQueryHistoryStore.shared.clearAll()

        // Clear stored VPN profiles too (legacy user-supplied configs may contain private keys).
        Persistence.clearVPNProfiles()

        // Persisted tab session — otherwise session restore resurrects every open URL on next launch.
        // (The in-memory tabs are reset by BrowserState.performPanicWipe, which drives this wipe.)
        Persistence.clearTabSession()

        // Password vault: delete every secret from the dedicated Keychain service + clear metadata.
        // This is a core privacy expectation — "nuke everything" must include saved logins/credentials.
        // (PasswordVaultManager lives in the isolated Passwords/ folder; only the clear hook is here.)
        PasswordVaultManager.shared.clearAllVaultData()

        // Also nuke any custom vault password verifier / biometric token for the vault-only lock.
        VaultLockManager.shared.clearAllVaultLockData()

        // (Privacy Power Hub + Holders Community + Wallet state clears removed — those entire systems deleted for general-use focus.
        // Passwords vault, history, bookmarks, VPN, web data, and LocalAI clears remain.)

        // Encryption key: rotate (or delete) so any previously copied/exfiltrated encrypted
        // AppData can no longer be decrypted with the key left in this Mac's Keychain.
        if dataEncryptionEnabled {
            // Read the (already wiped) data under the OLD key before replacing it.
            let remaining = Persistence.load()
            let newKey = DataEncryptor.generateKey()
            if KeychainManager.saveKey(newKey) {
                Persistence.save(remaining)
                Log.privacy.notice("PrivacyManager: at-rest encryption key rotated as part of panic wipe")
            } else {
                Log.security.error("PrivacyManager: panic wipe could not rotate the encryption key; keeping the old key so data stays writable")
            }
        } else {
            // Encryption off: normal policy retains the key so old backups stay recoverable.
            // Panic wipe is the explicit "leave nothing behind" action — delete it.
            if KeychainManager.deleteKey() {
                Log.privacy.notice("PrivacyManager: retained encryption key deleted as part of panic wipe")
            }
        }

        clearStandardWebData {
            if stopLocalSearxng {
                Task { @MainActor in
                    await LocalSearxngManager.shared.stop()
                    Log.privacy.notice("PrivacyManager: panic wipe also stopped the local SearXNG process")
                    // New in Phase 0: also nuke any in-memory AI state (synthesis, rewrite badge, open chat sheet, etc.)
                    // The manager itself will unload models when the master toggle is forced off by UI or other paths.
                    // We call through BrowserState if a reference is available; otherwise the next load will see clean state.
                    LocalIntelligenceManager.shared.clearCurrentChatTranscript()
                    NotificationCenter.default.post(name: Notification.Name("Searxly.LocalAIClearRequested"), object: nil)
                    completion?()
                }
            } else {
                LocalIntelligenceManager.shared.clearCurrentChatTranscript()
                NotificationCenter.default.post(name: Notification.Name("Searxly.LocalAIClearRequested"), object: nil)
                completion?()
            }
        }

        // Post a special notification so the UI can show a dramatic "Everything cleared" banner if desired
        NotificationCenter.default.post(name: Notification.Name("Searxly.PanicWipeCompleted"), object: nil)
        Log.privacy.notice("PrivacyManager: *** PANIC WIPE COMPLETED ***")
    }

    // MARK: - Clear Operations

    /// Clears persisted history (long-term visit log). Does NOT touch web cookies/storage.
    func clearHistory() {
        clearHistory(since: nil)
    }

    /// Clears history entries on or after the given date. Pass nil for all time.
    func clearHistory(since: Date?) {
        var current = Persistence.load()
        if let since {
            current.history.removeAll { $0.date < since }
        } else {
            current.history = []
        }
        Persistence.save(current)

        NotificationCenter.default.post(name: Self.historyClearedNotification, object: nil)
        // P5: if RAG was using history, drop the in-memory index so the next retrieve/chat can't
        // surface items the user just asked to forget. Rebuild will happen on next use if RAG still enabled.
        LocalIntelligenceManager.shared.clearRAGIndex()
        Log.privacy.info("PrivacyManager: history cleared (since: \(since?.description ?? "all time"))")
    }

    /// Clears persisted bookmarks.
    func clearBookmarks() {
        Persistence.clearBookmarks()
        // P5: keep RAG index in sync with the cleared data.
        LocalIntelligenceManager.shared.clearRAGIndex()
    }

    /// Clears cookies, caches, localStorage, etc. for all *standard* (non-private) tabs.
    /// Private/ephemeral tabs use their own non-persistent stores and are unaffected.
    /// This is async; the completion is fire-and-forget for the UI.
    func clearStandardWebData(completion: (() -> Void)? = nil) {
        clearStandardWebData(since: nil, completion: completion)
    }

    /// Time-aware version. Pass a date to only remove data modified since then.
    func clearStandardWebData(since: Date?, completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default()

        let dataTypes: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeServiceWorkerRegistrations
        ]

        let cutoff = since ?? .distantPast
        store.removeData(ofTypes: dataTypes, modifiedSince: cutoff) {
            Log.privacy.info("PrivacyManager: standard tab website data cleared (since: \(since?.description ?? "all time"))")
            NotificationCenter.default.post(name: Self.standardWebDataClearedNotification, object: nil)
            completion?()
        }
    }

    /// "Forget this site" action.
    /// Best-effort removal of data associated with a specific domain (host).
    /// - Removes matching history entries
    /// - Removes matching bookmarks
    /// - Clears standard (non-private) website data (cookies, storage, cache, etc.)
    ///
    /// Note: True per-host data removal has limitations in WebKit. We clear all standard
    /// web data as a pragmatic privacy win. Private tabs are unaffected (they're already ephemeral).
    func forgetDomain(_ host: String, completion: (() -> Void)? = nil) {
        let normalizedHost = host.lowercased()

        // 1. Remove matching history
        var current = Persistence.load()
        current.history.removeAll { item in
            if let url = URL(string: item.url), let itemHost = url.host?.lowercased() {
                return itemHost == normalizedHost || itemHost.hasSuffix(".\(normalizedHost)")
            }
            return false
        }
        Persistence.save(current)
        NotificationCenter.default.post(name: Self.historyClearedNotification, object: nil)

        // 2. Remove matching bookmarks
        Persistence.clearBookmarks(matchingHost: normalizedHost)

        // 3. Clear standard web data (best effort for the domain)
        clearStandardWebData {
            Log.privacy.info("PrivacyManager: forget-domain completed for \(normalizedHost)")
            NotificationCenter.default.post(name: Self.standardWebDataClearedNotification, object: nil)
            completion?()
        }
    }

    /// Combined "Reset All Local Data" action.
    /// Clears suggestions + history + bookmarks + standard web data + VPN profiles (private keys from user configs).
    /// Callers can show their own confirmation UI.
    func resetAllLocalData(completion: (() -> Void)? = nil) {
        _performResetAllLocalData(completion: completion)
    }

    private func _performResetAllLocalData(completion: (() -> Void)?) {
        Persistence.clearHistory()
        Persistence.clearBookmarks()

        // Search-query suggestions have their own store (UserDefaults) — clear them for a real reset.
        SearchQueryHistoryStore.shared.clearAll()

        // Also clear VPN profiles (incl. private keys in user-provided configs).
        // This keeps "Clear all local data" / reset consistent with privacy goals.
        Persistence.clearVPNProfiles()

        // (Privacy Power Hub + Holders Community + Wallet state clears removed with those systems.
        // Only core data + VPN + vault + web data remain for this lighter reset path.)

        // Placeholder for web data clear (the three clear buttons handle it explicitly)
        // clearStandardWebData { ... }

        NotificationCenter.default.post(name: Self.allPrivacyDataClearedNotification, object: nil)
        completion?()
    }

    // MARK: - Convenience for Settings UI strings

    // These two are shown in Settings and MUST track the actual protection state: with at-rest
    // encryption on, AppData (history/bookmarks/tabs) is AES-GCM encrypted, so claiming "plaintext"
    // would be false. The file also lives in the app's sandboxed container (TCC-protected), not a
    // world-visible Application Support path — the old copy got both wrong.
    var historyStorageWarning: String {
        dataEncryptionEnabled
            ? "History (URLs, titles, dates) is stored in Searxly's private app container and encrypted at rest with your local key. Cookies and site data from Standard tabs are managed by macOS WebKit and aren't covered by Searxly's encryption."
            : "History (URLs, titles, dates) is stored unencrypted in Searxly's private app container. FileVault and macOS file permissions are the only protections — turn on \"Encrypt local data at rest\" below, or keep history off, if that's a concern."
    }

    var strongerDataWarning: String {
        dataEncryptionEnabled
            ? "Your history, bookmarks, and tab state are encrypted at rest on this Mac. Cookies and site storage from Standard tabs are managed by macOS and stay unencrypted — Private tabs leave almost nothing behind. \"Clear Browsing Data…\" removes both."
            : "Local data (history, bookmarks, suggestions, and cookies/site storage from Standard tabs) is stored unencrypted on this Mac. Private tabs are the main exception — they leave almost nothing behind. Turn on encryption below, clear data regularly, or keep history off."
    }

    /// Strong warning shown when user considers enabling encryption.
    var encryptionKeyLossWarning: String {
        "If you lose the encryption key (e.g. by resetting your Mac, deleting the app container, or Keychain issues), your encrypted data will become permanently unreadable. Consider exporting a recovery code when enabling this feature."
    }
}

