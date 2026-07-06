//
//  ExtensionsMarketplaceView.swift
//  Searxly
//
//  Full-page Extensions marketplace — an internal utility page (TabKind.extensions), opened like the
//  Passwords / Bookmarks pages. Browse + install + manage real browser extensions (Lane A). Reuses
//  ExtensionManager for everything; gated to macOS 15.4 (the engine's floor) with a graceful fallback.
//

import SwiftUI

struct ExtensionsMarketplaceView: View {
    let onClose: () -> Void

    @State private var installed: [LaneAExtensionSnapshot] = []
    @State private var catalogEntries: [ExtensionCatalogEntry] = []
    @State private var status: String?

    private var demoInstalled: Bool { installed.contains { $0.displayName == "Searxly Demo" } }
    private var installedIDs: Set<String> { Set(installed.map { $0.extensionID }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 26)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refresh()
            Task { catalogEntries = await ExtensionCatalogClient.fetch() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Extensions")
                    .font(.system(size: 16, weight: .bold))
                Text("Add features to Searxly — you control what each one can access.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if #available(macOS 15.4, *) {
            VStack(alignment: .leading, spacing: 26) {
                if !installed.isEmpty {
                    sectionTitle("Installed")
                    VStack(spacing: 12) {
                        ForEach(installed) { installedCard($0) }
                    }
                }

                sectionTitle("Discover")
                VStack(spacing: 12) {
                    discoverCard(
                        name: "Searxly Demo",
                        icon: "checkmark.seal.fill",
                        description: "A tiny demo that confirms extensions are working — shows a brief badge on the pages you visit.",
                        state: demoInstalled ? .installed : .install
                    ) { installDemo() }

                    if catalogEntries.isEmpty {
                        // No published catalog yet — show the famous open-source ones as upcoming.
                        discoverCard(name: "uBlock Origin Lite", icon: "shield.lefthalf.filled",
                                     description: "Efficient, privacy-friendly content blocker. Open-source.",
                                     state: .comingSoon) {}
                        discoverCard(name: "Dark Reader", icon: "moon.stars.fill",
                                     description: "Dark mode for every website, with per-site controls. Open-source.",
                                     state: .comingSoon) {}
                    } else {
                        ForEach(catalogEntries) { entry in
                            discoverCard(
                                name: entry.name,
                                icon: entry.icon ?? "puzzlepiece.extension.fill",
                                description: entry.description,
                                state: installedIDs.contains(entry.id) ? .installed : .install
                            ) { install(entry) }
                        }
                    }
                }

                if let status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label("Extensions run only with the access you grant, never in Private or Tor tabs, and nothing about them leaves this Mac.",
                      systemImage: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Extensions need macOS 15.4 or later")
                    .font(.system(size: 15, weight: .semibold))
                Text("Your version of macOS doesn't support the browser-extension engine yet. Userscripts (Settings → Extensions) still work.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    // MARK: - Cards

    private func installedCard(_ ext: LaneAExtensionSnapshot) -> some View {
        cardShell {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    iconTile("puzzlepiece.extension.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.displayName).font(.system(size: 14, weight: .semibold))
                        Text(ext.grantedHostCount > 0 ? "Active" : "Installed — no site access")
                            .font(.system(size: 11))
                            .foregroundStyle(ext.grantedHostCount > 0 ? Color.green : Color.secondary)
                    }
                    Spacer()
                }
                if !ext.requestedPermissions.isEmpty {
                    detailLine("Permissions", ext.requestedPermissions.joined(separator: ", "))
                }
                if !ext.requestedHosts.isEmpty {
                    detailLine("Runs on", ext.requestedHosts.joined(separator: "  "))
                }
                HStack(spacing: 8) {
                    if ext.grantedHostCount > 0 {
                        capsuleButton("Revoke access", role: .normal) { revoke(ext.id) }
                    } else {
                        capsuleButton("Grant access", role: .normal) { grant(ext.id) }
                    }
                    capsuleButton("Remove", role: .destructive) { uninstall(ext.id) }
                    Spacer()
                }
            }
        }
    }

    private enum DiscoverState { case install, installed, comingSoon }

    private func discoverCard(name: String, icon: String, description: String, state: DiscoverState, action: @escaping () -> Void) -> some View {
        cardShell {
            HStack(alignment: .top, spacing: 12) {
                iconTile(icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                switch state {
                case .install:
                    capsuleButton("Install", role: .prominent, action: action)
                case .installed:
                    Text("Installed").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                        .padding(.top, 4)
                case .comingSoon:
                    Text("Coming soon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    // MARK: - Building blocks

    private func cardShell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func iconTile(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 38, height: 38)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").foregroundStyle(.secondary) + Text(value).foregroundStyle(.secondary))
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum BtnRole { case normal, prominent, destructive }

    private func capsuleButton(_ title: String, role: BtnRole, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .prominent ? Color.black : (role == .destructive ? Color.red : Color.primary))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(
                    role == .prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func refresh() {
        if #available(macOS 15.4, *) {
            installed = ExtensionManager.shared.snapshots()
        }
    }

    private func installDemo() {
        guard #available(macOS 15.4, *) else { return }
        status = "Installing…"
        Task {
            do {
                try await ExtensionManager.shared.installBuiltInDemo()
                status = "Installed Searxly Demo. Open a new tab and visit any site — a small badge confirms it's running."
            } catch {
                status = "Install failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    private func install(_ entry: ExtensionCatalogEntry) {
        guard #available(macOS 15.4, *) else { return }
        status = "Installing \(entry.name)…"
        Task {
            do {
                try await ExtensionManager.shared.installFromCatalog(entry)
                status = "Installed \(entry.name). Open a new tab to use it."
            } catch {
                status = "Install failed: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    private func uninstall(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.uninstall(loadedID: id)
        status = "Removed."
        refresh()
    }

    private func grant(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.grantRequestedHosts(forLoadedID: id)
        refresh()
    }

    private func revoke(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.revokeAll(forLoadedID: id)
        refresh()
    }
}
