//
//  SearxlyPrivacyPill.swift
//  Searxly
//
//  Always-visible Maximum-Privacy status pill in the browser header (mirrors SearxlyVPNPill / TorPill
//  placement). Shown ONLY while the app is in Maximum Privacy mode; it reflects the fail-closed kill
//  switch state from PrivacyGate — protected, connecting, or blocked. Tapping opens a details panel
//  with the active network (Tor or Searxly VPN), status, quick reconnect, circuit rotate (Tor), and
//  switcher + settings link. Label shows "Maximum" (not "Private") when the kill switch is satisfied.
//

import SwiftUI

struct SearxlyPrivacyPill: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingPanel = false

    private let privacy = PrivacyManager.shared
    private let gate = PrivacyGate.shared
    private let vpn = SystemVPNManager.shared
    private let tor = TorManager.shared

    var glassEnabled: Bool = true
    var toolbarMaterial: Material = .regularMaterial

    private var isMaximum: Bool { privacy.appPrivacyMode == .maximum }
    private var usingTor: Bool { privacy.maxProtection == .tor }
    private var protected: Bool { gate.isWebProtected }

    private var connecting: Bool {
        if usingTor {
            if case .bootstrapping = tor.status { return true }
            return false
        }
        return vpn.status == .connecting || vpn.status == .reasserting
    }

    // Orange accent for the live protection status (protected = solid + glow, connecting = dimmed);
    // grey when blocked. This pill is the Maximum-Privacy indicator — the network (VPN/Tor) is shown
    // by the dedicated VPN/Tor pills, so we don't relabel this one "Tor".
    private var statusTint: Color {
        if protected { return .orange }
        if connecting { return .orange }
        return Color(white: 0.5)
    }

    private var title: String {
        if protected { return "Maximum" }
        if connecting { return "Connecting" }
        return "Blocked"
    }

    var body: some View {
        if isMaximum {
            Button { showingPanel = true } label: { label }
                .buttonStyle(.plain)
                .help(protected
                      ? "Maximum Privacy active via \(usingTor ? "Tor" : "Searxly VPN") — tap for details"
                      : "Maximum Privacy — protection not ready. Tap for details.")
                .popover(isPresented: $showingPanel, arrowEdge: .bottom) { panel }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: protected ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.3)
            statusDot
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(toolbarMaterial, in: Capsule())
        .searxlyGlass(glassEnabled ? .interactive : .clear, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                protected ? statusTint.opacity(0.5) : AdaptiveChrome.border(colorScheme, dark: 0.12),
                lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 6, height: 6)
            .opacity(connecting ? 0.45 : 1)
            .shadow(color: protected ? statusTint.opacity(0.7) : .clear, radius: 3)
            .animation(.easeInOut(duration: 0.25), value: protected)
    }

    // MARK: - Details panel (shown on tap)

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(AdaptiveChrome.border(colorScheme, dark: 0.12))

            if protected {
                protectedBody
            } else if connecting {
                connectingBody
            } else {
                blockedBody
            }

            Divider().overlay(AdaptiveChrome.border(colorScheme, dark: 0.12))

            actionsRow
            footerNote
        }
        .padding(16)
        .frame(width: 320)
        .background(
            AdaptiveChrome.dynamic(
                light: .white,
                dark: Color(red: 0.043, green: 0.043, blue: 0.051)
            )
        )
        // Populate the live Tor circuit when Tor is the active protection (the folded-in Tor content).
        .task { if usingTor { await TorManager.shared.refreshCircuit() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AdaptiveChrome.dynamic(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08)))
                    .frame(width: 30, height: 30)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Maximum Privacy").font(.system(size: 14, weight: .bold))
                Text(headerSubtitle).font(.system(size: 10.5)).foregroundStyle(statusTint)
            }
            Spacer()
            Circle().fill(statusTint)
                .frame(width: 8, height: 8)
                .shadow(color: protected ? statusTint.opacity(0.6) : .clear, radius: 3)
                .opacity(connecting ? 0.6 : 1)
        }
    }

    private var headerSubtitle: String {
        if protected { return usingTor ? "Protected via Tor" : "Protected via Searxly VPN" }
        if connecting { return "Connecting protection…" }
        return "Protection inactive"
    }

    private var protectedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash.fill").font(.system(size: 12, weight: .semibold))
                Text("Your IP is hidden").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Network")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(usingTor ? "Tor" : "Searxly VPN")
                        .font(.system(size: 12, weight: .semibold))
                }
                HStack(alignment: .top) {
                    Text("Coverage")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(usingTor
                         ? "Pages + local search (via Tor)"
                         : "All traffic (whole-device tunnel)")
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.top, 2)

            // Folded-in Tor content: the live 3-hop circuit visualization the standalone Tor pill used
            // to show (that pill is hidden in Maximum + Tor — see BrowserHeaderView.foldTorIntoMaximumPill).
            if usingTor {
                TorCircuitView(relays: tor.circuit, destinationHost: nil, tint: statusTint)
            }

            if usingTor && tor.status == .running {
                Button {
                    Task {
                        _ = await tor.newCircuit()
                        // The active tab will pick the new circuit on next nav / reload
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Request new Tor circuit")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(statusTint.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(statusTint.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(tor.rebuilding)
            }
        }
    }

    private var connectingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bringing protection online…")
                .font(.system(size: 13, weight: .semibold))
            Text(usingTor
                 ? "Tor is bootstrapping a circuit. Web and search traffic stay blocked until ready."
                 : "Connecting the Searxly VPN tunnel. All traffic will be covered once up.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await gate.ensureProtection() }
            } label: {
                Text("Retry connection")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(AdaptiveChrome.dynamic(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.1)), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var blockedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Traffic blocked for your protection")
                .font(.system(size: 13, weight: .semibold))
            Text(gate.blockReason ?? "Maximum Privacy is on. Connect your chosen protection (VPN or Tor) to resume browsing.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Surface the concrete Tor start failure (was previously swallowed — the pill only showed a
            // generic "connecting" line, so a failed "Start Tor" looked like it did nothing).
            if usingTor, let err = tor.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Button {
                Task { await gate.ensureProtection() }
            } label: {
                HStack(spacing: 6) {
                    if usingTor {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    } else {
                        Image(systemName: "lock.shield")
                    }
                    Text(usingTor ? "Start Tor" : "Connect VPN")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(statusTint.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(statusTint.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(connecting)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await gate.ensureProtection() }
            } label: {
                Text(protected ? "Reconnect" : "Connect")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showingPanel = false
                NotificationCenter.default.post(name: .openSettingsToPrivacy, object: nil)
            } label: {
                HStack(spacing: 3) {
                    Text("Privacy settings")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Quick switcher for the backing network. Searxly Maximum is Tor-only — the managed VPN
            // isn't part of that edition — so the VPN⇄Tor switcher is hidden there.
            if !Edition.isMaximum {
                Menu {
                    ForEach(MaxProtection.allCases, id: \.self) { opt in
                        Button {
                            if privacy.maxProtection != opt {
                                PrivacyManager.shared.setMaxProtection(opt)
                            }
                        } label: {
                            HStack {
                                Text(opt.displayName)
                                if privacy.maxProtection == opt {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: usingTor ? "point.3.connected.trianglepath.dotted" : "network.badge.shield.half.filled")
                            .font(.system(size: 10))
                        Text("Switch")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var footerNote: some View {
        Text("Fail-closed: if protection drops, pages and searches are blocked rather than leaking your IP.")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
