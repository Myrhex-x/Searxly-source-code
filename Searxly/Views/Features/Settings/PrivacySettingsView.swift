//
//  PrivacySettingsView.swift
//  Searxly
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

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: Localization.string("privacy_header"),
                subtitle: "Control what Searxly remembers, what gets filtered, and how your data is stored on this Mac."
            )

            SettingsSection(
                title: "Shortcuts",
                footer: "Maximum Privacy protects your browsing session. Secure this Mac adds disk encryption and App Lock for professionals who need physical-access protection."
            ) {
                SettingsProminentAction(
                    title: Localization.string("activate_max_privacy", defaultValue: "Maximum Privacy"),
                    systemImage: "shield.lefthalf.filled",
                    action: {
                        applyMaximumPrivacyPreset()
                    }
                )
                .help("Recommended. Private tabs by default, no history, clears web data, and disables Local AI.")

                Text("Recommended for everyday private browsing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsDivider()

                SettingsProminentAction(
                    title: Localization.string("secure_this_mac", defaultValue: "Secure this Mac"),
                    systemImage: "lock.shield.fill",
                    tint: .secondary,
                    action: {
                        applySecureMacPreset()
                    }
                )
                .help("Professional. Encryption, App Lock, no history, and copies your recovery code.")

                Text("Advanced — for professionals who need encrypted data at rest and biometric app lock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            SettingsCallout(
                title: "About local storage",
                message: PrivacyManager.shared.strongerDataWarning,
                tint: .orange,
                systemImage: "externaldrive.fill"
            )

            SettingsSection(title: "Browsing") {
                SettingsToggleRow(
                    title: Localization.string("save_browsing_history"),
                    description: "Keeps a list of sites you visit. Off by default is more private.",
                    isOn: $historyEnabled
                )
                .onChange(of: historyEnabled) { _, newValue in
                    Task { PrivacyManager.shared.setHistoryEnabled(newValue) }
                }

                SettingsDivider()

                SettingsToggleRow(
                    title: Localization.string("default_new_tabs_private"),
                    description: "⌘T opens a Private tab instead of a standard tab. ⌘⇧T always opens Private explicitly.",
                    isOn: $defaultNewTabsToPrivate
                )
                .onChange(of: defaultNewTabsToPrivate) { _, newValue in
                    Task { PrivacyManager.shared.setDefaultNewTabsToPrivate(newValue) }
                }

                if historyEnabled {
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

            SettingsSection(
                title: "SafeSearch",
                footer: "Filters adult content in search results. Not perfect — you can turn it off for unfiltered results."
            ) {
                SettingsToggleRow(
                    title: "Filter sensitive results",
                    description: "Like Google SafeSearch. Uses strict upstream filtering plus a local blocklist and keyword checks.",
                    isOn: Binding(
                        get: { SearchContentSafety.shared.isEnabled },
                        set: { SearchContentSafety.shared.isEnabled = $0 }
                    ),
                    badge: SearchContentSafety.shared.isEnabled ? "On" : nil
                )
            }

            SettingsSection(
                title: "Ad blocking",
                footer: "Reload the current page after changing this setting."
            ) {
                SettingsToggleRow(
                    title: "Block ads and trackers on websites",
                    description: "Uses bundled uBlock Origin filter lists (offline). Separate from search filtering.",
                    isOn: Binding(
                        get: { AdBlockManager.shared.isEnabled },
                        set: { newValue in Task { AdBlockManager.shared.setEnabled(newValue) } }
                    ),
                    badge: AdBlockManager.shared.isEnabled ? "On" : nil
                )
            }

            SettingsSection(
                title: "Encryption",
                footer: "Optional. Copy a recovery code after enabling — without it, encrypted data cannot be recovered."
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
                        } else if let code = PrivacyManager.shared.exportEncryptionRecoveryCode() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                            clearedMessage = Localization.string("recovery_code_copied")
                            showClearConfirmation = true
                        } else {
                            clearedMessage = Localization.string("no_encryption_key")
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled
                }
            }

            SettingsCallout(
                title: Localization.string("what_is_stored"),
                message: Localization.string("stored_items"),
                tint: .secondary,
                systemImage: "info.circle"
            )
        }
    }

    private func applyMaximumPrivacyPreset() {
        PrivacyManager.shared.enableStrictPrivacyMode()
        historyEnabled = PrivacyManager.shared.historyEnabled
        defaultNewTabsToPrivate = PrivacyManager.shared.defaultNewTabsToPrivate
        clearedMessage = Localization.string(
            "max_privacy_activated",
            defaultValue: "Maximum Privacy is on: new tabs open in Private mode, history is off, and standard web data was cleared."
        )
        showClearConfirmation = true
    }

    private func applySecureMacPreset() {
        let run = {
            let result = PrivacyManager.shared.enableSecureMacPreset()
            historyEnabled = PrivacyManager.shared.historyEnabled
            dataEncryptionEnabled = PrivacyManager.shared.dataEncryptionEnabled

            var message = Localization.string(
                "secure_mac_activated",
                defaultValue: "Secure Mac is on: history is off, local data is encrypted, and App Lock is enabled."
            )

            if let partial = result.partialError {
                message = partial
            } else if PrivacyManager.shared.exportSecureMacRecoveryCodeToClipboard() {
                message += " " + Localization.string(
                    "secure_mac_recovery_copied",
                    defaultValue: "Your recovery code was copied to the clipboard — store it somewhere safe."
                )
            }

            clearedMessage = message
            showClearConfirmation = true
        }

        if let reauth = requestReauth, AppLockManager.shared.requiresPINForSensitiveActions {
            reauth(run, nil)
        } else {
            run()
        }
    }
}