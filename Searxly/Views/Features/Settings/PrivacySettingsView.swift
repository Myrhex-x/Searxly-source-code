//
//  PrivacySettingsView.swift
//  Searxly
//
//  Privacy & Data pane. Organized top-down by how often people need it:
//    1. Privacy Mode   — the one ladder that drives everything (Normal ⊂ Encrypted ⊂ Maximum)
//    2. Browsing       — what Searxly remembers
//    3. Content filtering — SafeSearch + ad/tracker blocking
//    4. Your data      — encryption at rest, recovery code, clearing, honest storage notes
//    5. Get set up     — default browser + import (one-time actions, so they live last)
//
//  The old "Shortcuts" preset buttons were removed on purpose: they silently set the same modes
//  the Privacy Mode picker already sets, which meant two controls fighting over one state.
//

import SwiftUI

struct PrivacySettingsView: View {
    @Binding var historyEnabled: Bool
    @Binding var defaultNewTabsToPrivate: Bool
    @Binding var dataEncryptionEnabled: Bool
    @Binding var clearedMessage: String
    @Binding var showClearConfirmation: Bool
    @Binding var showingClearData: Bool

    var requestReauth: ((@escaping () -> Void, (() -> Void)?) -> Void)?
    var onExportRecovery: (() -> Void)?

    @State private var appPrivacyMode: AppPrivacyMode = .normal
    @State private var maxProtection: MaxProtection = .tor
    @State private var amnesiaPreference: Bool = AmnesiaMode.preference
    @State private var securityLevel: MaximumSecurityLevel = .standard

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Localization.string("privacy_header"),
                subtitle: "One privacy ladder, from fast to bulletproof — plus what Searxly remembers and how it's stored on this Mac."
            )

            privacyModeSection
            // Searxly Maximum edition features only: the live Privacy Self-Test, Network Ledger, Tor
            // bridges, and Amnesic mode are premium hardening and are absent from the base (free) app.
            if Edition.isMaximum {
                securityLevelSection
                PrivacySelfTestSection()
                NetworkLedgerSection()
                TorBridgesSection()
                amnesicSection
            }
            browsingSection
            filteringSection
            dataSection
            setupSection
        }
    }

    // MARK: - 1. Privacy Mode

    private var privacyModeSection: some View {
        Group {
            if Edition.isMaximum {
                lockedMaximumModeSection
            } else {
                editablePrivacyModeSection
            }
        }
    }

    /// Searxly Maximum: the ladder is not user-selectable — the app is permanently in Maximum
    /// Privacy over Tor. Show a read-only, locked panel instead of the picker.
    private var lockedMaximumModeSection: some View {
        SettingsSection(
            title: "Privacy Mode",
            footer: "Searxly Maximum runs permanently in Maximum Privacy — this can't be turned down, it's the point of this edition. Your fingerprint is scrambled and your data on this Mac is encrypted. You choose how your IP is hidden: Tor is the default and the most private; the Searxly VPN is faster, but you trust our exit node. Either way, if the lane isn't up, all traffic is blocked."
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maximum Privacy — always on")
                        .font(.callout.weight(.semibold))
                    Text("Locked on: IP protection, Strict fingerprint scrambling, at-rest encryption, and App Lock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            SettingsDivider()

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide my IP with")
                        .font(.callout)
                    Text(maxProtection == .tor
                         ? "Tor — most private, slower. The default."
                         : "Searxly VPN — faster, but you trust our exit node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Picker("", selection: $maxProtection) {
                    ForEach(MaxProtection.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: maxProtection) { _, newValue in
                    PrivacyManager.shared.setMaxProtection(newValue)
                    // setMaxProtection may coerce VPN → Tor if the (future) premium entitlement is locked;
                    // reflect the value that actually took effect.
                    maxProtection = PrivacyManager.shared.maxProtection
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                maxProtection = PrivacyManager.shared.maxProtection
            }
        }
    }

    private var editablePrivacyModeSection: some View {
        SettingsSection(
            title: "Privacy Mode",
            footer: "Normal and Encrypted keep every site working. Maximum Privacy hides your IP behind the Searxly VPN or Tor — or blocks all traffic if neither is up — and scrambles your browser fingerprint. Much harder to track, but some sites may break."
        ) {
            Picker("", selection: $appPrivacyMode) {
                ForEach(AppPrivacyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: appPrivacyMode) { oldValue, newValue in
                guard newValue != PrivacyManager.shared.appPrivacyMode else { return }
                applyAppPrivacyMode(newValue, revertTo: oldValue)
            }

            Text(appPrivacyMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if appPrivacyMode == .maximum {
                SettingsDivider()

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide my IP with")
                            .font(.callout)
                        Text(maxProtection.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $maxProtection) {
                        ForEach(MaxProtection.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: maxProtection) { _, newValue in
                        PrivacyManager.shared.setMaxProtection(newValue)
                    }
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                appPrivacyMode = PrivacyManager.shared.appPrivacyMode
                maxProtection = PrivacyManager.shared.maxProtection
            }
        }
    }

    // MARK: - 1a. Security level (Tor-Browser-style slider) — Maximum only

    private var securityLevelSection: some View {
        SettingsSection(
            title: "Security Level",
            footer: "Like Tor Browser's slider. Higher levels shrink what a malicious page can do — the biggest residual risk in any browser is a JavaScript-engine exploit (historically the way Tor users have been deanonymised). Safest turns JavaScript off on the web; your local search still works. Reload a page to apply a change."
        ) {
            Picker("", selection: $securityLevel) {
                ForEach(MaximumSecurityLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: securityLevel) { _, newValue in
                MaximumSecurity.shared.setLevel(newValue)
            }

            Text(securityLevel.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            DispatchQueue.main.async { securityLevel = MaximumSecurity.shared.level }
        }
    }

    // MARK: - 1b. Amnesic mode

    private var amnesicSection: some View {
        SettingsSection(
            title: "Amnesic mode",
            footer: "When on, Searxly runs entirely in memory — browsing history, open tabs, cookies, and cache are never written to disk and are gone the moment you quit. Your bookmarks, saved passwords, and settings are kept. Takes full effect at the next launch."
        ) {
            SettingsToggleRow(
                title: "Leave no trace on disk",
                description: "RAM-only browsing: nothing about what you do this session survives quitting.",
                isOn: $amnesiaPreference,
                badge: AmnesiaMode.isActive ? "Active" : (amnesiaPreference ? "Next launch" : nil)
            )
            .onChange(of: amnesiaPreference) { _, newValue in
                AmnesiaMode.preference = newValue
            }

            if amnesiaPreference && !AmnesiaMode.isActive {
                Text("Relaunch Searxly to start an amnesic session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if AmnesiaMode.isActive && !amnesiaPreference {
                Text("Amnesic mode stays active until you relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 2. Browsing

    private var browsingSection: some View {
        SettingsSection(title: "Browsing") {
            SettingsToggleRow(
                title: Localization.string("save_browsing_history"),
                description: "Keeps a list of sites you visit. Off by default is more private.",
                isOn: $historyEnabled
            )
            .onChange(of: historyEnabled) { _, newValue in
                // Persist synchronously (not in a deferred Task): otherwise toggling and then
                // immediately quitting can terminate the app before the task runs, and the
                // quit-time save preserves the old on-disk value — the setting silently reverts.
                PrivacyManager.shared.setHistoryEnabled(newValue)
            }

            SettingsDivider()

            SettingsToggleRow(
                title: Localization.string("default_new_tabs_private"),
                description: "⌘T opens a Private tab instead of a standard tab. ⌘⇧T always opens Private explicitly.",
                isOn: $defaultNewTabsToPrivate
            )
            .onChange(of: defaultNewTabsToPrivate) { _, newValue in
                // Persist synchronously — same durability reason as history above.
                PrivacyManager.shared.setDefaultNewTabsToPrivate(newValue)
            }

            if Edition.isMaximum {
                SettingsDivider()

                SettingsToggleRow(
                    title: "Auto-upgrade to .onion when offered",
                    description: "When a site advertises a Tor onion mirror, open it automatically — end-to-end encrypted, with no exit node. Otherwise Searxly just offers a banner.",
                    isOn: Binding(
                        get: { OnionPreferences.autoUpgrade },
                        set: { OnionPreferences.autoUpgrade = $0 }
                    ),
                    badge: OnionPreferences.autoUpgrade ? "On" : nil
                )
            }

            if historyEnabled {
                // Encryption-aware: says "encrypted at rest" only when it actually is.
                Text(PrivacyManager.shared.historyStorageWarning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                historyEnabled = PrivacyManager.shared.historyEnabled
                defaultNewTabsToPrivate = PrivacyManager.shared.defaultNewTabsToPrivate
            }
        }
    }

    // MARK: - 3. Content filtering

    private var filteringSection: some View {
        SettingsSection(
            title: "Content filtering",
            footer: "Ad blocking uses bundled uBlock Origin filter lists, fully offline. Reload open pages after changing it."
        ) {
            SettingsToggleRow(
                title: "Block ads and trackers on websites",
                description: "Removes ads, trackers, and annoyances while pages load.",
                isOn: Binding(
                    // Call directly: setEnabled persists the flag synchronously and defers its
                    // own (heavy) rule compilation internally. Wrapping it in a Task risked the
                    // write being lost if the app quit before the task ran.
                    get: { AdBlockManager.shared.isEnabled },
                    set: { newValue in AdBlockManager.shared.setEnabled(newValue) }
                ),
                badge: AdBlockManager.shared.isEnabled ? "On" : nil
            )

            SettingsDivider()

            SettingsToggleRow(
                title: "SafeSearch — filter sensitive results",
                description: "Like Google SafeSearch: strict upstream filtering plus a local blocklist. Not perfect; turn off for unfiltered results.",
                isOn: Binding(
                    get: { SearchContentSafety.shared.isEnabled },
                    set: { SearchContentSafety.shared.isEnabled = $0 }
                ),
                badge: SearchContentSafety.shared.isEnabled ? "On" : nil
            )
        }
    }

    // MARK: - 4. Your data on this Mac

    private var dataSection: some View {
        Group {
            SettingsSection(
                title: "Your data on this Mac",
                footer: "Copy a recovery code after enabling encryption — without it, encrypted data cannot be recovered if your Keychain is lost."
            ) {
                SettingsToggleRow(
                    title: Localization.string("encrypt_local_data"),
                    description: "Encrypts history, bookmarks, instances, and tab state using CryptoKit and your Keychain.",
                    isOn: $dataEncryptionEnabled,
                    badge: dataEncryptionEnabled ? "On" : nil
                )
                .onChange(of: dataEncryptionEnabled) { oldValue, newValue in
                    let action = { PrivacyManager.shared.setDataEncryptionEnabled(newValue) }
                    if let reauth = requestReauth, AppLockManager.shared.requiresPINForSensitiveActions {
                        reauth(action) { dataEncryptionEnabled = oldValue }
                    } else {
                        action()
                    }
                }

                if dataEncryptionEnabled {
                    SettingsDivider()

                    SettingsActionChip(
                        title: Localization.string("copy_recovery_code"),
                        systemImage: "key"
                    ) {
                        if let export = onExportRecovery {
                            export()
                        } else if PrivacyManager.shared.copyEncryptionRecoveryCodeToClipboard() {
                            clearedMessage = Localization.string("recovery_code_copied")
                            showClearConfirmation = true
                        } else {
                            clearedMessage = Localization.string("no_encryption_key")
                            showClearConfirmation = true
                        }
                    }
                }

                SettingsDivider()

                SettingsActionChip(
                    title: Localization.string("clear_browsing_data"),
                    systemImage: "trash",
                    role: .destructive
                ) {
                    showingClearData = true
                }

                Text("Choose exactly what to remove — history, cookies, cache, and more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                DispatchQueue.main.async {
                    dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled
                }
            }

            // Honest, state-aware storage note: orange only while data is actually unencrypted.
            SettingsCallout(
                title: "How your data is protected",
                message: PrivacyManager.shared.strongerDataWarning,
                tint: dataEncryptionEnabled ? .secondary : .orange,
                systemImage: dataEncryptionEnabled ? "lock.fill" : "externaldrive.fill"
            )

            SettingsCallout(
                title: Localization.string("what_is_stored"),
                message: Localization.string("stored_items"),
                tint: .secondary,
                systemImage: "info.circle"
            )
        }
    }

    // MARK: - 5. Get set up

    private var setupSection: some View {
        SettingsSection(
            title: "Get set up",
            footer: DefaultBrowserManager.shared.isDefault
                ? "Searxly is your default browser — links from Mail, Messages, and other apps open here."
                : "Make Searxly your default so links from other apps open here — then your private browsing covers everything, not just what you start in the app."
        ) {
            if DefaultBrowserManager.shared.isDefault {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Text("Searxly is your default browser.")
                        .font(.callout)
                    Spacer(minLength: 0)
                }
            } else {
                SettingsProminentAction(
                    title: "Make Searxly the Default Browser",
                    systemImage: "globe",
                    action: { DefaultBrowserManager.shared.makeDefault() }
                )
                .help("Asks macOS to set Searxly as the handler for http and https links.")
            }

            SettingsDivider()

            SettingsProminentAction(
                title: "Import Data from Another Browser",
                systemImage: "square.and.arrow.down.on.square",
                tint: .secondary,
                action: {
                    NotificationCenter.default.post(name: .importDataRequested, object: nil)
                }
            )
            .help("Brings bookmarks (exported HTML) and passwords (CSV) over from Safari, Chrome, Firefox, and others.")
        }
        .onAppear { DefaultBrowserManager.shared.refresh() }
    }

    // MARK: - Mode application

    /// Applies an app privacy mode from the picker. Encrypted/Maximum enable encryption + App Lock,
    /// so they're gated behind re-auth when a vault PIN is required; on cancel the picker reverts
    /// to `previous`. All dependent toggles resync from PrivacyManager afterwards.
    private func applyAppPrivacyMode(_ mode: AppPrivacyMode, revertTo previous: AppPrivacyMode? = nil) {
        let run = {
            PrivacyManager.shared.setAppPrivacyMode(mode)
            appPrivacyMode = PrivacyManager.shared.appPrivacyMode
            maxProtection = PrivacyManager.shared.maxProtection
            historyEnabled = PrivacyManager.shared.historyEnabled
            dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled
            defaultNewTabsToPrivate = PrivacyManager.shared.defaultNewTabsToPrivate
        }

        if mode != .normal, let reauth = requestReauth, AppLockManager.shared.requiresPINForSensitiveActions {
            reauth(run, { appPrivacyMode = previous ?? PrivacyManager.shared.appPrivacyMode })
        } else {
            run()
        }
    }
}
