//
//  Persistence.swift
//  Searxly
//
//  Simple, reliable JSON file persistence for a learning project.
//  Stores: SearXNG instances, history, and bookmarks.
//

import Foundation
import os

// MARK: - App Data Container

struct AppData: Codable {
    var searxInstances: [SearXNGInstance] = []  // No public defaults; user must configure private/local instance
    var history: [HistoryItem] = []
    var bookmarks: [BookmarkItem] = []
    /// Persisted ID of the currently selected SearXNG instance (so the user's choice, e.g. their Local instance, survives restarts).
    var currentInstanceID: String? = nil

    /// Whether browsing history (visit log) should be recorded. Stored here for atomicity with the rest of the sensitive data.
    /// When false, new navigation does not append to history (existing entries remain until explicitly cleared).
    var historyEnabled: Bool = false

    /// When true, the regular "New Tab" command creates a Private (ephemeral) tab by default.
    /// "New Private Tab" (⌘⇧T) always creates a private tab regardless of this setting.
    /// This is the main lever for "Maximum privacy" vs "Balanced" experience.
    var defaultNewTabsToPrivate: Bool = true

    /// Stores the list of open tabs (URL + privacy mode) so they can be restored on next launch.
    /// Moving this out of UserDefaults reduces sensitive data living in unprotected storage.
    var tabSnapshots: [TabSnapshot] = []

    // Tab Hibernation settings (Performance category)
    var tabHibernationEnabled: Bool = true
    var tabHibernationMaxActiveTabs: Int = 8
    var tabHibernationInactivityTimeout: Int = 600  // seconds (10 min)

    // Auto Tab Cleanup (opt-in "Auto Whatever" feature — only in Settings, off by default)
    var autoTabCleanupEnabled: Bool = false
    /// Seconds of inactivity before a standard tab is eligible for auto-close (0 = never)
    var autoCloseUnusedAfterSeconds: Int = 86400          // 24h suggested default when enabled
    /// Separate (usually stricter) rule for private/ephemeral tabs
    var autoClosePrivateTabsAfterSeconds: Int = 3600      // 1 hour
    /// When total open tabs exceeds this number, the oldest unused background tabs are closed (0 = disabled)
    var autoCloseWhenExceedsTabCount: Int = 0
    /// Whether to automatically close background tabs when the user quits the app
    var autoCloseBackgroundTabsOnQuit: Bool = false

    // App Lock (biometric) settings — stored here so they are encrypted when "Encrypt local data at rest" is enabled.
    var appLockEnabled: Bool = false
    var appLockInactivityMinutes: Int = 5
    var appLockRequireOnNextLaunch: Bool = true

    // WireGuard VPN – own servers only (users bring their own WireGuard configs for full system tunnel).
    // Stored in AppData so profiles (which contain private keys) participate in optional at-rest encryption.
    // The manager (in the dedicated VPN/ folder) owns the runtime behavior.
    var vpnProfiles: [VPNProfile] = []

    /// When true (and at least one own server profile exists), show the VPN quick control pill at the
    /// top-left of the content area (browser toolbar when web, or pane top-left). Opens popover.
    /// User-controlled convenience affordance (gated in Settings > VPN).
    var vpnBrowserControlsEnabled: Bool = false

    // Local on-device AI preferences (Phase 0+).
    // Stored inside AppData so it is automatically encrypted when the user enables "Encrypt local data at rest".
    // All individual feature toggles default to false (master off). The manager may still use a transient
    // UserDefaults master flag during early scaffolding; the canonical value will live here after migration.
    var aiPreferences: AIPreferences = .default

    // Password Vault (on-device encrypted credential manager).
    // Metadata only (domain, username, notes, timestamps, tags). The actual passwords live exclusively
    // in PasswordVaultSecureStore (Keychain with userPresence protection).
    // This field participates in optional at-rest encryption (via EncryptedDataStore) and in encrypted backups.
    // Terminology: entries / logins / credentials — never "accounts" (Searxly value: no accounts inside the app).
    var passwordVaultEntries: [PasswordVaultEntry] = []

    // Vault-specific protection (separate from full App Lock).
    // When true, the Password Vault has its own unlock flow (custom passphrase possible) instead of
    // always relying on the global AppLock / device owner authentication.
    // The actual per-entry secrets remain protected by Keychain userPresence in all cases.
    var passwordVaultUseCustomPassword: Bool = false

    // When custom password is enabled, these allow verifying a user-entered passphrase.
    // Salt + a verifier (we store a PBKDF2-derived hash of the passphrase).
    // These live in AppData so they benefit from the main optional at-rest encryption.
    var passwordVaultCustomSalt: Data?
    var passwordVaultCustomVerifier: Data?   // derived hash for verification

    // Optional: when user has "enrolled biometrics for vault", we store a random unlock token
    // in the passwords Keychain service (protected by userPresence). Loading it successfully
    // proves the user passed device auth and allows marking the vault unlocked for the session.
    // (The token itself is not the custom password; it's a bearer for this device only.)

    // Vault auto-lock timeout (in minutes). Default 10. 0 = never (not recommended).
    // This is independent of the full App Lock inactivity timer.
    var passwordVaultAutoLockMinutes: Int = 10

    // Password vault browser behavior (autofill + save offers). Stored in AppData for encryption parity.
    var passwordVaultAutofillEnabled: Bool = true
    var passwordVaultOfferToSaveEnabled: Bool = true
    var passwordVaultSuggestPasswordsEnabled: Bool = true
    var passwordVaultCopyGeneratedToClipboard: Bool = true

    /// SERP right-column knowledge panel (entity + dictionary cards via private SearXNG only).
    var knowledgePanelEnabled: Bool = true

    // Custom decoder for backward compatibility.
    // Older AppData.json files won't have the newer keys (historyEnabled, defaultNewTabsToPrivate, tabSnapshots).
    // We use decodeIfPresent + defaults so upgrades don't spam errors and fall back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        searxInstances     = try container.decodeIfPresent([SearXNGInstance].self, forKey: .searxInstances) ?? []
        history            = try container.decodeIfPresent([HistoryItem].self,    forKey: .history) ?? []
        bookmarks          = try container.decodeIfPresent([BookmarkItem].self,   forKey: .bookmarks) ?? []
        currentInstanceID  = try container.decodeIfPresent(String.self,           forKey: .currentInstanceID)

        historyEnabled            = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? false
        defaultNewTabsToPrivate   = try container.decodeIfPresent(Bool.self, forKey: .defaultNewTabsToPrivate) ?? true
        tabSnapshots = try container.decodeIfPresent([TabSnapshot].self, forKey: .tabSnapshots) ?? []

        tabHibernationEnabled = try container.decodeIfPresent(Bool.self, forKey: .tabHibernationEnabled) ?? true
        tabHibernationMaxActiveTabs      = try container.decodeIfPresent(Int.self, forKey: .tabHibernationMaxActiveTabs) ?? 8
        tabHibernationInactivityTimeout  = try container.decodeIfPresent(Int.self, forKey: .tabHibernationInactivityTimeout) ?? 600

        autoTabCleanupEnabled             = try container.decodeIfPresent(Bool.self, forKey: .autoTabCleanupEnabled) ?? false
        autoCloseUnusedAfterSeconds       = try container.decodeIfPresent(Int.self, forKey: .autoCloseUnusedAfterSeconds) ?? 86400
        autoClosePrivateTabsAfterSeconds  = try container.decodeIfPresent(Int.self, forKey: .autoClosePrivateTabsAfterSeconds) ?? 3600
        autoCloseWhenExceedsTabCount      = try container.decodeIfPresent(Int.self, forKey: .autoCloseWhenExceedsTabCount) ?? 0
        autoCloseBackgroundTabsOnQuit     = try container.decodeIfPresent(Bool.self, forKey: .autoCloseBackgroundTabsOnQuit) ?? false

        appLockEnabled            = try container.decodeIfPresent(Bool.self, forKey: .appLockEnabled) ?? false
        appLockInactivityMinutes  = try container.decodeIfPresent(Int.self, forKey: .appLockInactivityMinutes) ?? 5
        appLockRequireOnNextLaunch = try container.decodeIfPresent(Bool.self, forKey: .appLockRequireOnNextLaunch) ?? true

        vpnProfiles = try container.decodeIfPresent([VPNProfile].self, forKey: .vpnProfiles) ?? []
        vpnBrowserControlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnBrowserControlsEnabled) ?? false

        // NEW Phase 0 — safe decode (older files get the .default which has everything off)
        aiPreferences = try container.decodeIfPresent(AIPreferences.self, forKey: .aiPreferences) ?? .default

        // Password Vault (new dedicated feature). Safe decode for older AppData.json files.
        passwordVaultEntries = try container.decodeIfPresent([PasswordVaultEntry].self, forKey: .passwordVaultEntries) ?? []

        passwordVaultUseCustomPassword = try container.decodeIfPresent(Bool.self, forKey: .passwordVaultUseCustomPassword) ?? false
        passwordVaultCustomSalt = try container.decodeIfPresent(Data.self, forKey: .passwordVaultCustomSalt)
        passwordVaultCustomVerifier = try container.decodeIfPresent(Data.self, forKey: .passwordVaultCustomVerifier)

        passwordVaultAutoLockMinutes = try container.decodeIfPresent(Int.self, forKey: .passwordVaultAutoLockMinutes) ?? 10

        passwordVaultAutofillEnabled = try container.decodeIfPresent(Bool.self, forKey: .passwordVaultAutofillEnabled) ?? true
        passwordVaultOfferToSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .passwordVaultOfferToSaveEnabled) ?? true
        passwordVaultSuggestPasswordsEnabled = try container.decodeIfPresent(Bool.self, forKey: .passwordVaultSuggestPasswordsEnabled) ?? true
        passwordVaultCopyGeneratedToClipboard = try container.decodeIfPresent(Bool.self, forKey: .passwordVaultCopyGeneratedToClipboard) ?? true

        knowledgePanelEnabled = try container.decodeIfPresent(Bool.self, forKey: .knowledgePanelEnabled) ?? true
    }

    // Memberwise initializer (needed because we have custom init(from:) + init()).
    init(
        searxInstances: [SearXNGInstance] = [],
        history: [HistoryItem] = [],
        bookmarks: [BookmarkItem] = [],
        currentInstanceID: String? = nil,
        historyEnabled: Bool = false,
        defaultNewTabsToPrivate: Bool = true,
        tabSnapshots: [TabSnapshot] = [],
        tabHibernationEnabled: Bool = true,
        tabHibernationMaxActiveTabs: Int = 8,
        tabHibernationInactivityTimeout: Int = 600,
        // Auto Tab Cleanup
        autoTabCleanupEnabled: Bool = false,
        autoCloseUnusedAfterSeconds: Int = 86400,
        autoClosePrivateTabsAfterSeconds: Int = 3600,
        autoCloseWhenExceedsTabCount: Int = 0,
        autoCloseBackgroundTabsOnQuit: Bool = false,
        // App Lock
        appLockEnabled: Bool = false,
        appLockInactivityMinutes: Int = 5,
        appLockRequireOnNextLaunch: Bool = true,

        // WireGuard VPN (profiles contain secrets for user's own servers)
        vpnProfiles: [VPNProfile] = [],
        vpnBrowserControlsEnabled: Bool = false,

        // Local on-device AI preferences (Phase 0+). Persisted so encryption applies automatically.
        aiPreferences: AIPreferences = .default,

        // Password Vault metadata (secrets stay in Keychain via PasswordVaultSecureStore).
        passwordVaultEntries: [PasswordVaultEntry] = [],

        // Vault-only protection (custom passphrase support)
        passwordVaultUseCustomPassword: Bool = false,
        passwordVaultCustomSalt: Data? = nil,
        passwordVaultCustomVerifier: Data? = nil,

        // Vault auto-lock
        passwordVaultAutoLockMinutes: Int = 10,

        passwordVaultAutofillEnabled: Bool = true,
        passwordVaultOfferToSaveEnabled: Bool = true,
        passwordVaultSuggestPasswordsEnabled: Bool = true,
        passwordVaultCopyGeneratedToClipboard: Bool = true,
        knowledgePanelEnabled: Bool = true
    ) {
        self.searxInstances = searxInstances
        self.history = history
        self.bookmarks = bookmarks
        self.currentInstanceID = currentInstanceID
        self.historyEnabled = historyEnabled
        self.defaultNewTabsToPrivate = defaultNewTabsToPrivate
        self.tabSnapshots = tabSnapshots
        self.tabHibernationEnabled = tabHibernationEnabled
        self.tabHibernationMaxActiveTabs = tabHibernationMaxActiveTabs
        self.tabHibernationInactivityTimeout = tabHibernationInactivityTimeout
        self.autoTabCleanupEnabled = autoTabCleanupEnabled
        self.autoCloseUnusedAfterSeconds = autoCloseUnusedAfterSeconds
        self.autoClosePrivateTabsAfterSeconds = autoClosePrivateTabsAfterSeconds
        self.autoCloseWhenExceedsTabCount = autoCloseWhenExceedsTabCount
        self.autoCloseBackgroundTabsOnQuit = autoCloseBackgroundTabsOnQuit

        self.appLockEnabled = appLockEnabled
        self.appLockInactivityMinutes = appLockInactivityMinutes
        self.appLockRequireOnNextLaunch = appLockRequireOnNextLaunch

        self.vpnProfiles = vpnProfiles
        self.vpnBrowserControlsEnabled = vpnBrowserControlsEnabled

        self.aiPreferences = aiPreferences
        self.passwordVaultEntries = passwordVaultEntries

        self.passwordVaultUseCustomPassword = passwordVaultUseCustomPassword
        self.passwordVaultCustomSalt = passwordVaultCustomSalt
        self.passwordVaultCustomVerifier = passwordVaultCustomVerifier

        self.passwordVaultAutoLockMinutes = passwordVaultAutoLockMinutes

        self.passwordVaultAutofillEnabled = passwordVaultAutofillEnabled
        self.passwordVaultOfferToSaveEnabled = passwordVaultOfferToSaveEnabled
        self.passwordVaultSuggestPasswordsEnabled = passwordVaultSuggestPasswordsEnabled
        self.passwordVaultCopyGeneratedToClipboard = passwordVaultCopyGeneratedToClipboard
        self.knowledgePanelEnabled = knowledgePanelEnabled
    }

    init() {}   // Convenience empty init for defaults

    // We must declare CodingKeys because we have a custom init(from:).
    private enum CodingKeys: String, CodingKey {
        case searxInstances
        case history
        case bookmarks
        case currentInstanceID
        case historyEnabled
        case defaultNewTabsToPrivate
        case tabSnapshots
        case tabHibernationEnabled
        case tabHibernationMaxActiveTabs
        case tabHibernationInactivityTimeout

        // Auto Tab Cleanup
        case autoTabCleanupEnabled
        case autoCloseUnusedAfterSeconds
        case autoClosePrivateTabsAfterSeconds
        case autoCloseWhenExceedsTabCount
        case autoCloseBackgroundTabsOnQuit

        // App Lock (biometrics) — encrypted when data encryption is on
        case appLockEnabled
        case appLockInactivityMinutes
        case appLockRequireOnNextLaunch

        // VPN (own servers only)
        case vpnProfiles
        case vpnBrowserControlsEnabled

        // Local on-device AI (Phase 0+)
        case aiPreferences

        // Password Vault (metadata only; actual secrets in dedicated Keychain service)
        case passwordVaultEntries

        // Vault-specific lock / custom password (in addition to per-secret Keychain protection)
        case passwordVaultUseCustomPassword
        case passwordVaultCustomSalt
        case passwordVaultCustomVerifier

        // Vault auto-lock timeout (minutes)
        case passwordVaultAutoLockMinutes

        case passwordVaultAutofillEnabled
        case passwordVaultOfferToSaveEnabled
        case passwordVaultSuggestPasswordsEnabled
        case passwordVaultCopyGeneratedToClipboard
        case knowledgePanelEnabled
    }
}

// MARK: - Persistence Manager

enum Persistence {
    private static let fileName = "AppData.json"
    
    private static var fileURL: URL {
        appDataFileURL()
    }

    /// Public accessor for the main AppData.json location.
    /// Used by EncryptedDataStore so we don't need duplicate logic or temporary extensions.
    static func appDataFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("Searxly", isDirectory: true)
        
        // Ensure directory exists.
        // We also try to mark it with protection attributes where supported.
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        
        // Best-effort: protect the directory itself (helps on some macOS configurations).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: appDirectory.path
        )
        
        return appDirectory.appendingPathComponent(fileName)
    }
    
    /// Loads all app data from disk. Falls back to sensible defaults.
    /// When data encryption is enabled, this goes through EncryptedDataStore.
    static func load() -> AppData {
        // EncryptedDataStore handles both plaintext and encrypted paths transparently.
        let appData = EncryptedDataStore.load()
        // (verbose load logging removed to reduce console spam during normal use)
        return appData
    }
    
    /// Saves the current app data to disk.
    /// When data encryption is enabled, this goes through EncryptedDataStore.
    static func save(_ data: AppData) {
        EncryptedDataStore.save(data)
    }
    
    /// Convenience: Save just the instances (preserves other fields including currentInstanceID)
    static func saveInstances(_ instances: [SearXNGInstance]) {
        var current = load()
        current.searxInstances = instances
        save(current)
    }

    /// Save the selected current instance ID (and instances if provided).
    static func saveCurrentInstanceID(_ id: UUID?, instances: [SearXNGInstance]? = nil) {
        var current = load()
        current.currentInstanceID = id?.uuidString
        if let instances {
            current.searxInstances = instances
        }
        save(current)
    }
    
    /// Convenience: Save just history
    static func saveHistory(_ history: [HistoryItem]) {
        var current = load()
        current.history = history
        save(current)
    }
    
    /// Convenience: Save just bookmarks
    static func saveBookmarks(_ bookmarks: [BookmarkItem]) {
        var current = load()
        current.bookmarks = bookmarks
        save(current)
    }

    // MARK: - Privacy-focused clear helpers (used by PrivacyManager)
    // These keep the storage layer responsible for read-modify-write.

    static func clearHistory() {
        var current = load()
        current.history = []
        save(current)
        Log.privacy.info("Persistence: history cleared")
    }

    static func clearBookmarks() {
        var current = load()
        current.bookmarks = []
        save(current)
        Log.privacy.info("Persistence: bookmarks cleared")
    }

    /// Clears only bookmarks whose URL host matches the given normalized host (or subdomain).
    static func clearBookmarks(matchingHost: String) {
        var current = load()
        let before = current.bookmarks.count
        current.bookmarks.removeAll { bookmark in
            if let url = URL(string: bookmark.url), let host = url.host?.lowercased() {
                return host == matchingHost || host.hasSuffix(".\(matchingHost)")
            }
            return false
        }
        if current.bookmarks.count != before {
            save(current)
            Log.privacy.info("Persistence: cleared bookmarks matching host \(matchingHost)")
        }
    }

    /// Updates the historyEnabled preference atomically inside AppData.json.
    /// This replaces the previous @AppStorage approach for better atomicity with history/bookmarks.
    static func setHistoryEnabled(_ enabled: Bool) {
        var current = load()
        current.historyEnabled = enabled
        save(current)
        Log.privacy.info("Persistence: historyEnabled set to \(enabled, privacy: .public)")
    }

    /// One-time migration: if the old UserDefaults key exists, pull its value into AppData and remove the key.
    static func migrateHistoryEnabledIfNeeded() {
        let oldKey = "Searxly.HistoryEnabled"
        if UserDefaults.standard.object(forKey: oldKey) != nil {
            let oldValue = UserDefaults.standard.bool(forKey: oldKey)
            var data = load()
            data.historyEnabled = oldValue
            save(data)
            UserDefaults.standard.removeObject(forKey: oldKey)
            Log.app.info("Persistence: migrated historyEnabled from UserDefaults to AppData.json (value: \(oldValue, privacy: .public))")
        }
    }

    static func setKnowledgePanelEnabled(_ enabled: Bool) {
        var current = load()
        current.knowledgePanelEnabled = enabled
        save(current)
    }

    static func knowledgePanelEnabled() -> Bool {
        load().knowledgePanelEnabled
    }

    /// Updates the default tab privacy preference atomically.
    static func setDefaultNewTabsToPrivate(_ enabled: Bool) {
        var current = load()
        current.defaultNewTabsToPrivate = enabled
        save(current)
        Log.privacy.info("Persistence: defaultNewTabsToPrivate set to \(enabled, privacy: .public)")
    }

    /// One-time migration for the new default tab privacy preference.
    static func migrateDefaultTabPrivacyIfNeeded() {
        let oldKey = "Searxly.DefaultNewTabsToPrivate"
        if UserDefaults.standard.object(forKey: oldKey) != nil {
            let oldValue = UserDefaults.standard.bool(forKey: oldKey)
            var data = load()
            data.defaultNewTabsToPrivate = oldValue
            save(data)
            UserDefaults.standard.removeObject(forKey: oldKey)
            Log.app.info("Persistence: migrated defaultNewTabsToPrivate from UserDefaults (value: \(oldValue, privacy: .public))")
        }
    }

    // MARK: - Tab session snapshots (now stored inside AppData.json for better consistency)
    static func saveTabSnapshots(_ snapshots: [TabSnapshot]) {
        var current = load()
        current.tabSnapshots = snapshots
        save(current)
    }

    static func loadTabSnapshots() -> [TabSnapshot] {
        return load().tabSnapshots
    }

    /// One-time migration helper (safe to call on launch).
    /// Moves old UserDefaults-based snapshots into AppData.json and cleans up legacy keys.
    static func migrateLegacySessionIfNeeded() {
        let legacyKey = "Searxly.LastSessionURLs"
        let snapshotsKey = "Searxly.LastTabSnapshots"

        var migrated = false

        // Migrate from the newest UserDefaults snapshot key
        if let data = UserDefaults.standard.data(forKey: snapshotsKey),
           let decoded = try? JSONDecoder().decode([TabSnapshot].self, from: data),
           !decoded.isEmpty {
            var current = load()
            current.tabSnapshots = decoded
            save(current)
            UserDefaults.standard.removeObject(forKey: snapshotsKey)
            migrated = true
            Log.app.info("Persistence: migrated tab snapshots from UserDefaults into AppData.json")
        }

        // Clean up the very old plain URL array key
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            migrated = true
            Log.app.info("Persistence: removed legacy session URL array from UserDefaults")
        }

        if migrated {
            Log.app.info("Persistence: session snapshot migration complete")
        }
    }

    // MARK: - Password Vault (metadata only — passwords live in PasswordVaultSecureStore in the Keychain)
    // The vault is a first-class privacy feature. Entries participate in optional at-rest encryption
    // and encrypted backups exactly like appLock preferences.
    // "Accounts" terminology is deliberately avoided (Searxly value: no accounts inside the app).

    static func savePasswordVaultEntries(_ entries: [PasswordVaultEntry]) {
        var current = load()
        current.passwordVaultEntries = entries
        save(current)
    }

    static func loadPasswordVaultEntries() -> [PasswordVaultEntry] {
        return load().passwordVaultEntries
    }

    static func savePasswordVaultLockConfig(useCustom: Bool, salt: Data?, verifier: Data?) {
        var current = load()
        current.passwordVaultUseCustomPassword = useCustom
        current.passwordVaultCustomSalt = salt
        current.passwordVaultCustomVerifier = verifier
        save(current)
    }

    static func loadPasswordVaultLockConfig() -> (useCustom: Bool, salt: Data?, verifier: Data?) {
        let d = load()
        return (d.passwordVaultUseCustomPassword, d.passwordVaultCustomSalt, d.passwordVaultCustomVerifier)
    }

    static func savePasswordVaultAutoLockMinutes(_ minutes: Int) {
        var current = load()
        current.passwordVaultAutoLockMinutes = max(0, min(minutes, 1440)) // cap at 24h
        save(current)
    }

    static func loadPasswordVaultAutoLockMinutes() -> Int {
        return load().passwordVaultAutoLockMinutes
    }

    static func loadPasswordVaultBehaviorPreferences() -> (
        autofillEnabled: Bool,
        offerToSaveEnabled: Bool,
        suggestPasswordsEnabled: Bool,
        copyGeneratedToClipboard: Bool
    ) {
        let d = load()
        return (
            d.passwordVaultAutofillEnabled,
            d.passwordVaultOfferToSaveEnabled,
            d.passwordVaultSuggestPasswordsEnabled,
            d.passwordVaultCopyGeneratedToClipboard
        )
    }

    static func savePasswordVaultBehaviorPreferences(
        autofillEnabled: Bool,
        offerToSaveEnabled: Bool,
        suggestPasswordsEnabled: Bool,
        copyGeneratedToClipboard: Bool
    ) {
        var current = load()
        current.passwordVaultAutofillEnabled = autofillEnabled
        current.passwordVaultOfferToSaveEnabled = offerToSaveEnabled
        current.passwordVaultSuggestPasswordsEnabled = suggestPasswordsEnabled
        current.passwordVaultCopyGeneratedToClipboard = copyGeneratedToClipboard
        save(current)
    }
}