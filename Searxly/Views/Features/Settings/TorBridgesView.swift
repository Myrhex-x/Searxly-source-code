//
//  TorBridgesView.swift
//  Searxly
//
//  Settings UI for Tor bridges + pluggable transports (see TorBridgeConfig). Lets the user pick a
//  transport, paste obfs4 bridge lines, and reconnect Tor so it can reach the network on censored /
//  hostile connections. Shown whenever the bundled Tor runtime is present.
//

import SwiftUI

struct TorBridgesSection: View {
    private let tor = TorManager.shared
    private let bridges = TorBridgeSettings.shared
    @State private var applying = false

    var body: some View {
        if tor.isAvailable {
            SettingsSection(
                title: "Tor bridges",
                footer: "Use bridges when Tor is blocked on your network. obfs4 needs bridge lines from the Tor Project (bridges.torproject.org, or email bridges@torproject.org). Snowflake needs no setup. Changing this reconnects Tor."
            ) {
                transportPicker
                Text(bridges.transport.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if Edition.isMaximum && bridges.transport == .none && bridges.snowflakeAvailable {
                    SettingsDivider()
                    autoFallbackToggle
                }

                if bridges.transport == .obfs4 {
                    SettingsDivider()
                    obfs4Editor
                }

                if bridges.isEnabled && !bridges.transportBinaryAvailable {
                    SettingsDivider()
                    unavailableWarning
                }

                SettingsDivider()
                applyRow
            }
        }
    }

    private var transportPicker: some View {
        Picker("", selection: Binding(
            get: { bridges.transport },
            set: { bridges.transport = $0 }
        )) {
            ForEach(TorBridgeTransport.allCases, id: \.self) { t in
                Text(t.displayName).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var autoFallbackToggle: some View {
        Toggle(isOn: Binding(
            get: { bridges.autoFallbackToSnowflake },
            set: { bridges.autoFallbackToSnowflake = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fall back to Snowflake automatically")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                Text("If a direct Tor connection looks blocked, retry through Snowflake without asking.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(SettingsTheme.inkFill)
    }

    private var obfs4Editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bridge lines")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
            Text("One per line, e.g. “obfs4 12.34.56.78:443 FINGERPRINT cert=… iat-mode=0”.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textTertiary)
            TextEditor(text: Binding(
                get: { bridges.obfs4Lines },
                set: { bridges.obfs4Lines = $0 }
            ))
            .font(.system(size: 11.5, design: .monospaced))
            .frame(minHeight: 72, maxHeight: 130)
            .padding(6)
            .scrollContentBackground(.hidden)
            .background(SettingsTheme.fillFaint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsTheme.hairline, lineWidth: 1))

            if let link = URL(string: "https://bridges.torproject.org") {
                Link(destination: link) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10, weight: .semibold))
                        Text("Get obfs4 bridges").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(SettingsTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var unavailableWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.warning)
            Text("This transport's helper binary isn't bundled in the current build. Re-run scripts/fetch-tor-runtime.sh to include pluggable transports, then rebuild. Until then Tor connects directly.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applyRow: some View {
        HStack(spacing: 10) {
            statusLabel
            Spacer(minLength: 8)
            Button {
                applying = true
                Task {
                    await tor.restartForConfigChange()
                    applying = false
                }
            } label: {
                HStack(spacing: 6) {
                    if applying { ProgressView().controlSize(.small) }
                    Text(applying ? "Reconnecting…" : "Apply & reconnect")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SettingsTheme.inkFill, in: Capsule())
                .foregroundStyle(SettingsTheme.onInk)
            }
            .buttonStyle(.plain)
            .disabled(applying || !bridges.isReady)
        }
    }

    private var statusLabel: some View {
        Group {
            if !bridges.isEnabled {
                Text("Direct Tor connection")
            } else if !bridges.transportBinaryAvailable {
                Text("Transport unavailable")
            } else if !bridges.isReady {
                Text("Add at least one bridge line")
            } else {
                Text("\(bridges.transport.displayName) ready")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(SettingsTheme.textSecondary)
    }
}
