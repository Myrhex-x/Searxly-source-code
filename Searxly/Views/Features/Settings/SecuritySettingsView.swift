//
//  SecuritySettingsView.swift
//  Searxly
//

import SwiftUI

struct SecuritySettingsView: View {
    var onCreateBackup: () -> Void = {}
    var onRestoreBackup: () -> Void = {}

    @State private var secureMacAlertMessage: String?
    @State private var showSecureMacAlert = false

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "App Security",
                subtitle: Edition.isMaximum
                    ? "Access control for the application itself — biometric App Lock, idle auto-lock, and encrypted backup."
                    : "Require Touch ID or your Mac password to open Searxly, and back up your data."
            )

            SettingsSection(
                title: "App Lock",
                footer: "Also required before changing encryption, exporting recovery codes, or resetting data."
            ) {
                SettingsToggleRow(
                    title: "Require authentication to use Searxly",
                    description: "Lock on launch, after inactivity, or when you choose Lock Now.",
                    isOn: Binding(
                        get: { AppLockManager.shared.isAppLockEnabled },
                        set: { newValue in
                            if !newValue && AppLockManager.shared.isAppLockEnabled {
                                AppLockManager.shared.performSensitiveAction {
                                    AppLockManager.shared.setAppLockEnabled(false)
                                }
                            } else {
                                AppLockManager.shared.setAppLockEnabled(newValue)
                            }
                        }
                    ),
                    badge: AppLockManager.shared.isAppLockEnabled ? "On" : nil
                )

                if AppLockManager.shared.isAppLockEnabled {
                    SettingsDivider()

                    SettingsPickerRow(
                        title: "Lock after",
                        selection: Binding(
                            get: { AppLockManager.shared.inactivityLockMinutes },
                            set: { AppLockManager.shared.setInactivityLockMinutes($0) }
                        )
                    ) {
                        Picker("", selection: Binding(
                            get: { AppLockManager.shared.inactivityLockMinutes },
                            set: { AppLockManager.shared.setInactivityLockMinutes($0) }
                        )) {
                            Text("Never").tag(0)
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    SettingsToggleRow(
                        title: "Lock when Searxly reopens",
                        description: "Ask for authentication the next time you launch the app after quitting.",
                        isOn: Binding(
                            get: { AppLockManager.shared.requireOnNextLaunchAfterQuit },
                            set: { AppLockManager.shared.setRequireOnNextLaunchAfterQuit($0) }
                        )
                    )

                    HStack(spacing: 12) {
                        Button {
                            AppLockManager.shared.lock()
                        } label: {
                            Label("Lock now", systemImage: "lock.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)

                        Button {
                            Task {
                                _ = await AppLockManager.shared.authenticateWithBiometrics(
                                    reason: "Test App Lock"
                                )
                            }
                        } label: {
                            Label("Test Touch ID", systemImage: "touchid")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
            }

            if AppLockManager.shared.isAppLockEnabled && PrivacyManager.shared.dataEncryptionEnabled {
                SettingsCallout(
                    title: "Encryption unlocks with App Lock",
                    message: "Unlocking Searxly also unlocks encrypted data for this session. macOS may show two prompts — that is expected.",
                    tint: .green,
                    systemImage: "lock.shield.fill"
                )
            }

            // Hardware security key (FIDO2 / YubiKey) as a second factor. Self-gates to Developer Mode
            // until the webcredentials:searxly.app associated domain + AASA file are deployed.
            SecurityKeySettingsSection()

            SettingsSection(
                title: "Backup & restore",
                footer: "Saves bookmarks, history, instances, and optionally your encryption key into one encrypted file."
            ) {
                HStack(spacing: 12) {
                    Button(action: onCreateBackup) {
                        Label("Back up now…", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.bordered)

                    Button(action: onRestoreBackup) {
                        Label("Restore…", systemImage: "externaldrive.badge.timemachine")
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsSection(
                title: "Professional",
                footer: "For physical-access protection on shared or high-risk Macs. Everyday users should use Maximum Privacy in Settings → Privacy & Data."
            ) {
                Button {
                    applySecureMacPreset()
                } label: {
                    Label(
                        Localization.string("secure_this_mac", defaultValue: "Secure this Mac"),
                        systemImage: "lock.shield.fill"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Text("Enables encryption, App Lock, disables history, and copies your recovery code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BiometricAuthNote(compact: true)
        }
        .alert("Secure this Mac", isPresented: $showSecureMacAlert) {
            Button("OK") { }
        } message: {
            Text(secureMacAlertMessage ?? "")
        }
    }

    private func applySecureMacPreset() {
        let run = {
            let result = PrivacyManager.shared.enableSecureMacPreset()

            var message = Localization.string(
                "secure_mac_activated",
                defaultValue: "Secure Mac is on: history is off, local data is encrypted, and App Lock is enabled."
            )

            if let partial = result.partialError {
                message = partial
            } else if PrivacyManager.shared.copyEncryptionRecoveryCodeToClipboard() {
                message += " " + Localization.string(
                    "secure_mac_recovery_copied",
                    defaultValue: "Your recovery code was copied — paste it somewhere safe now; the clipboard clears itself after 45 seconds."
                )
            }

            secureMacAlertMessage = message
            showSecureMacAlert = true
        }

        if AppLockManager.shared.requiresPINForSensitiveActions {
            AppLockManager.shared.performSensitiveAction(run)
        } else {
            run()
        }
    }
}