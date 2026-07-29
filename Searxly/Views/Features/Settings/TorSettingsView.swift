//
//  TorSettingsView.swift
//  Searxly
//
//  Settings → Tor / Onion Sites. Status, bundled version, activity log, and the honest disclosure.
//  Mirrors the InstancesSettingsView pattern (reads a shared @Observable manager) and the Settings
//  design-system primitives.
//

import SwiftUI

struct TorSettingsView: View {
    @Bindable private var tor = TorManager.shared
    @State private var showLogs = false

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Tor / Onion Sites",
                subtitle: Edition.isMaximum
                    ? "The bundled Tor client and .onion reachability. In Searxly Maximum, Tor is the always-on protection lane — every tab and native request already rides it. This pane governs onion-service specifics: hidden-service tabs, circuits, and onion auto-upgrade."
                    : "Reach .onion hidden services over the bundled Tor client. Off by default — onion tabs route through Tor without touching normal browsing. Separate from Maximum Privacy, which can also route search and app traffic over Tor (Settings → Privacy & Data)."
            )

            if !tor.isAvailable {
                SettingsCallout(
                    title: "Tor runtime not bundled",
                    message: "The Tor client isn’t included in this build, so .onion sites can’t open yet. (Developer: run scripts/fetch-tor-runtime.sh, then rebuild.)",
                    tint: SettingsTheme.danger,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            SettingsSection(
                title: "Onion routing",
                footer: "When on, opening a .onion address routes that tab through the bundled Tor client. Tor starts on your first onion and stops when the last onion tab closes."
            ) {
                SettingsToggleRow(
                    title: "Enable Tor for onion sites",
                    description: "Hides your IP and reaches .onion services with no DNS leaks. Not a Tor Browser replacement (see below).",
                    isOn: $tor.isEnabled
                )
            }

            if tor.isEnabled {
                SettingsSection(title: "Status") {
                    statusRow
                    SettingsDivider()
                    infoRow(label: "Bundled Tor", value: tor.bundledVersion)
                    SettingsDivider()
                    infoRow(label: "SOCKS proxy", value: "\(tor.socksHost):\(tor.socksPort)")

                    if tor.isRunning {
                        SettingsDivider()
                        SettingsActionChip(title: "Stop Tor", systemImage: "stop.circle") {
                            Task { await TorManager.shared.stop() }
                        }
                    }
                }

                SettingsSection(title: "Activity") {
                    SettingsActionChip(title: showLogs ? "Hide log" : "View log",
                                       systemImage: "text.alignleft") {
                        showLogs.toggle()
                    }
                    if showLogs {
                        SettingsInsetPanel {
                            if tor.logs.isEmpty {
                                Text("No Tor activity yet.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(SettingsTheme.textTertiary)
                            } else {
                                Text(tor.logs.suffix(40).joined(separator: "\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(SettingsTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            SettingsCallout(
                title: "This is not Tor Browser",
                message: "Tor routing hides your IP and lets you reach .onion services with no DNS leaks, and Searxly blocks the highest-signal leaks (WebRTC, geolocation) in onion tabs. It is not a full Tor Browser replacement and does not provide Tor Browser’s complete anti-fingerprinting. For maximum anonymity, use the official Tor Browser.",
                tint: SettingsTheme.warning,
                systemImage: "hand.raised.fill"
            )
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 18)
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
            Spacer()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsTheme.textTertiary)
        }
    }

    // MARK: - Status mapping

    private var statusText: String {
        switch tor.status {
        case .stopped: return "Not running"
        case .bootstrapping(let p): return p > 0 ? "Connecting to Tor… \(p)%" : "Connecting to Tor…"
        case .running: return "Connected"
        case .stopping: return "Stopping…"
        case .error(let m): return "Error — \(m)"
        }
    }

    private var statusTint: Color {
        switch tor.status {
        case .running: return SettingsTheme.green   // "live/status" — the one sanctioned use of green
        case .bootstrapping: return SettingsTheme.warning
        case .error: return SettingsTheme.danger
        default: return SettingsTheme.textTertiary
        }
    }

    private var statusIcon: String {
        switch tor.status {
        case .running: return "checkmark.circle.fill"
        case .bootstrapping: return "circle.dotted"
        case .error: return "exclamationmark.triangle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "circle"
        }
    }
}
