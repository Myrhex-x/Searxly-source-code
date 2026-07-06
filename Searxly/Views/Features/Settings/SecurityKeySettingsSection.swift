//
//  SecurityKeySettingsSection.swift
//  Searxly
//
//  Settings UI for enrolling and managing hardware security keys (FIDO2 / YubiKey) and choosing where
//  they're required as a second factor. See SecurityKeyManager for the model.
//
//  Gated behind Developer Mode for now: the feature can't succeed at runtime until the
//  `webcredentials:www.searxly.app` associated domain + AASA file are deployed and the app is team-signed
//  (see docs/SECURITY-KEYS.md). Once that's live, drop the Developer-Mode gate to expose it to everyone.
//

import SwiftUI

struct SecurityKeySettingsSection: View {
    @State private var manager = SecurityKeyManager.shared
    @State private var isEnrolling = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        if DeveloperSettings.shared.isEnabled {
            SettingsSection(
                title: "Security keys (experimental)",
                footer: "Adds a hardware security key (e.g. YubiKey) as a second factor on top of Touch ID. Requires macOS to be set up for webcredentials:www.searxly.app — see docs/SECURITY-KEYS.md. The key unlocks/decrypts only; it never signs wallet transactions (that stays with Ledger)."
            ) {
                SettingsToggleRow(
                    title: "Use a hardware security key",
                    description: "Master switch. Enroll at least two keys (one as a backup), then choose where a key is required below.",
                    isOn: Binding(
                        get: { manager.isFeatureEnabled },
                        set: { manager.isFeatureEnabled = $0 }
                    ),
                    badge: manager.isFeatureEnabled ? "On" : nil
                )

                SettingsDivider()

                // Enrolled keys
                if manager.credentials.isEmpty {
                    Text("No keys enrolled yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.credentials) { cred in
                        HStack(spacing: 10) {
                            Image(systemName: "key.radiowaves.forward.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cred.name).font(.system(size: 12.5, weight: .medium))
                                Text("Added \(cred.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                manager.removeCredential(cred)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this key")
                            .accessibilityLabel(Text("Remove \(cred.name)"))
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button {
                    enroll()
                } label: {
                    Label(isEnrolling ? "Waiting for key…" : "Add a security key…", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isEnrolling)
                .padding(.top, 2)

                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Anti-lockout: require a backup before any "require key" toggle can be armed.
                if !manager.meetsBackupRequirement {
                    SettingsCallout(
                        title: "Enroll a backup key",
                        message: "Add at least two keys before requiring one. If your only key is lost you could be locked out — a backup (or the recovery code / seed phrase) is your way back in.",
                        tint: .orange,
                        systemImage: "exclamationmark.shield.fill"
                    )
                }

                // Per-area requirements — only when the feature is on AND a backup key exists.
                if manager.isFeatureEnabled && manager.meetsBackupRequirement {
                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Require for App Lock",
                        description: "After Touch ID, also tap a key to unlock Searxly. (App Lock must be on.)",
                        isOn: Binding(get: { manager.requireForAppLock }, set: { manager.requireForAppLock = $0 })
                    )
                    SettingsToggleRow(
                        title: "Require for Password Vault",
                        description: "Tap a key to unlock the vault.",
                        isOn: Binding(get: { manager.requireForVault }, set: { manager.requireForVault = $0 })
                    )
                    SettingsToggleRow(
                        title: "Require for Wallet",
                        description: "Tap a key to open the wallet. (Signing transactions still uses your Ledger.)",
                        isOn: Binding(get: { manager.requireForWallet }, set: { manager.requireForWallet = $0 })
                    )
                }
            }
        }
    }

    private func enroll() {
        isEnrolling = true
        status = nil
        Task {
            let result = await manager.enroll(name: "")
            await MainActor.run {
                isEnrolling = false
                switch result {
                case .success(let cred):
                    status = "Added “\(cred.name)”." + (manager.meetsBackupRequirement ? "" : " Add one more as a backup.")
                    statusIsError = false
                case .failure(let message):
                    status = message
                    statusIsError = true
                }
            }
        }
    }
}
