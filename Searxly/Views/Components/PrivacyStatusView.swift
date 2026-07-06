//
//  PrivacyStatusView.swift
//  Searxly
//
//  Compact "site privacy" popover shown from the address-bar leading icon — the place users click to
//  check a page's security and control what it's allowed to do. Honest by design: it surfaces only
//  protections Searxly can actually attest to (connection security, Tor routing, ad/tracker blocking)
//  plus real per-site controls (camera/microphone permission, clear this site's data). It deliberately
//  does NOT show a per-page "trackers blocked" count — WebKit's content-rule-list blocking runs in the
//  network process and reports no counts back to the app, so any number would be guesswork.
//

import SwiftUI
import WebKit

struct PrivacyStatusView: View {
    /// Registrable host of the current page (e.g. "example.com"). Empty on home/search.
    let host: String
    let isOnionTab: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var adBlockEnabled = AdBlockManager.shared.isEnabled
    @State private var clearedData = false
    @State private var installedExtensions: [LaneAExtensionSnapshot] = []
    @State private var enabledHere: [String: Bool] = [:]

    private var hasSite: Bool { !host.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // Connection. Onion rides Tor; everything else on the open web is HTTPS because the app
            // enforces HTTPS-only for clearnet at the network layer (App Transport Security).
            statusRow(
                icon: isOnionTab ? "point.3.connected.trianglepath.dotted" : "lock.fill",
                title: isOnionTab ? "Routed through Tor" : "Connection is secure",
                subtitle: isOnionTab
                    ? "Your IP is hidden and the .onion address is verified end-to-end."
                    : "Searxly enforces HTTPS — the open web loads over an encrypted connection."
            )

            if hasSite {
                Divider()
                sectionLabel("Permissions on \(host)")
                permissionRow(.camera)
                permissionRow(.microphone)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { adBlockEnabled },
                set: { newValue in
                    adBlockEnabled = newValue
                    AdBlockManager.shared.setEnabled(newValue)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ad & tracker blocking")
                        .font(.system(size: 13, weight: .semibold))
                    Text(adBlockEnabled
                         ? "Known ad and tracker requests are blocked."
                         : "Blocking is currently off for all sites.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if hasSite, !installedExtensions.isEmpty {
                Divider()
                sectionLabel("Extensions on \(host)")
                ForEach(installedExtensions) { ext in
                    extensionRow(ext)
                }
            }

            if hasSite {
                Divider()
                Button(role: .destructive) {
                    clearSiteData()
                } label: {
                    Label(clearedData ? "Site data cleared" : "Clear data for this site",
                          systemImage: clearedData ? "checkmark" : "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(clearedData)
                .help("Removes cookies, cache, and stored data for \(host).")
            }

            Divider()

            Label("No accounts, no telemetry — your browsing never leaves this Mac.", systemImage: "hand.raised.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { loadExtensions() }
    }

    // MARK: - Extensions (per-extension, per-site)

    private func loadExtensions() {
        guard hasSite, ExtensionInstallStore.hasInstalled(), #available(macOS 15.4, *) else { return }
        let snaps = ExtensionManager.shared.snapshots()
        installedExtensions = snaps
        var map: [String: Bool] = [:]
        for s in snaps { map[s.extensionID] = ExtensionSiteStore.isEnabled(extensionID: s.extensionID, host: host) }
        enabledHere = map
    }

    private func extensionRow(_ ext: LaneAExtensionSnapshot) -> some View {
        let on = enabledHere[ext.extensionID] ?? true
        let running = ext.grantedHostCount > 0 && on
        let subtitle = ext.grantedHostCount == 0
            ? "No site access — turn it on in Extensions."
            : (running ? "Running on \(host)." : "Paused on \(host) — reload to apply.")
        return Toggle(isOn: Binding(
            get: { enabledHere[ext.extensionID] ?? true },
            set: { newValue in
                enabledHere[ext.extensionID] = newValue
                if #available(macOS 15.4, *) {
                    ExtensionManager.shared.setExtensionEnabled(newValue, extensionID: ext.extensionID, forHost: host)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ext.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .disabled(ext.grantedHostCount == 0)
    }

    // MARK: - Rows

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func permissionRow(_ permission: SitePermission) -> some View {
        let current = SitePermissionStore.shared.decision(permission, for: host)
        return HStack(spacing: 11) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(width: 22)
            Text(permission.label)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            Menu {
                ForEach(SitePermissionDecision.allCases, id: \.self) { decision in
                    Button {
                        SitePermissionStore.shared.set(decision, permission, for: host)
                    } label: {
                        if decision == current {
                            Label(decision.label, systemImage: "checkmark")
                        } else {
                            Text(decision.label)
                        }
                    }
                }
            } label: {
                Text(current.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func statusRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    /// Removes cookies, cache, and stored data for this host from the persistent (standard-tab) data
    /// store, and forgets any per-site permission overrides. Private/onion tabs keep nothing on disk,
    /// so this targets the shared default store where standard-tab data lives.
    private func clearSiteData() {
        let target = host.lowercased()
        SitePermissionStore.shared.clear(host: target)

        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return target == name || target.hasSuffix("." + name) || name.hasSuffix("." + target)
            }
            store.removeData(ofTypes: types, for: matching) { }
        }
        clearedData = true
    }
}
