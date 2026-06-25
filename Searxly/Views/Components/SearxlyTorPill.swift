//
//  SearxlyTorPill.swift
//  Searxly
//
//  Always-visible "Tor" control in the browser header (mirrors SearxlyVPNPill placement). Tapping
//  opens a panel that, when idle, invites the user to open a .onion site, and when active shows a
//  Tor-Browser-style circuit visualization of how the current onion tab is being routed. Drives
//  TorManager. The destination host (if the active tab is an onion tab) is passed in by the header.
//

import SwiftUI

struct SearxlyTorPill: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingPanel = false

    private var tor: TorManager { TorManager.shared }

    var glassEnabled: Bool = true
    var toolbarMaterial: Material = .regularMaterial
    /// Host of the active onion tab, when one is selected — shown as the circuit destination.
    var onionHost: String? = nil
    /// Provided by the header (which can reach the active web view): NEWNYM + reload the onion tab.
    var onNewCircuit: (() -> Void)? = nil

    private var connected: Bool { tor.status == .running }
    private var bootstrapPercent: Int? {
        if case .bootstrapping(let p) = tor.status { return p }
        return nil
    }
    private var connecting: Bool { bootstrapPercent != nil }
    private var active: Bool { connected || connecting }

    private var statusTint: Color {
        if connected { return TorPillTheme.green }
        if connecting { return TorPillTheme.amber }
        if case .error = tor.status { return TorPillTheme.red }
        return Color(white: 0.5)
    }

    var body: some View {
        Button { showingPanel = true } label: { label }
            .buttonStyle(.plain)
            .help(connected ? "Connected to Tor — tap to see your circuit"
                            : "Tor — tap to browse .onion sites")
            .popover(isPresented: $showingPanel, arrowEdge: .bottom) { panel }
    }

    // MARK: - Pill label

    private var labelText: String {
        if let p = bootstrapPercent, p > 0 { return "Tor \(p)%" }
        return "Tor"
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .semibold))
            Text(labelText)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.3)
                .monospacedDigit()
            statusDot
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(toolbarMaterial, in: Capsule())
        .glassEffect(glassEnabled ? .regular.interactive() : .clear, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                connected ? statusTint.opacity(0.5) : AdaptiveChrome.border(colorScheme, dark: 0.12),
                lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 6, height: 6)
            .opacity(connecting ? 0.5 : 1)
            .shadow(color: connected ? statusTint.opacity(0.7) : .clear, radius: 3)
            .animation(.easeInOut(duration: 0.25), value: connected)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if active {
                TorCircuitView(relays: tor.circuit, destinationHost: onionHost, tint: statusTint)
                if connected {
                    ipHiddenRow
                    if let onNewCircuit {
                        Button {
                            onNewCircuit()
                        } label: {
                            HStack(spacing: 6) {
                                if tor.rebuilding {
                                    ProgressView().controlSize(.small).tint(.white)
                                    Text("Building new circuit…").font(.system(size: 12, weight: .semibold))
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
                                    Text("New circuit for this site").font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(tor.rebuilding)
                    }
                }
            } else {
                stoppedBody
            }

            Text("This is not Tor Browser and doesn’t replace its full anti-fingerprinting.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .background(TorPillTheme.canvas)
        .preferredColorScheme(.dark)
        .task { await TorManager.shared.refreshCircuit() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 30, height: 30)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Tor").font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(statusTint)
            }
            Spacer()
            Circle().fill(statusTint).frame(width: 8, height: 8)
                .shadow(color: connected ? statusTint.opacity(0.7) : .clear, radius: 4)
        }
    }

    private var stoppedBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Browse .onion sites privately")
                .font(.system(size: 12.5, weight: .semibold))
            Text("Open a hidden service and Searxly routes that tab through the Tor network — bouncing your traffic across relays so your IP stays hidden.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TorCircuitView(relays: [], destinationHost: nil, tint: Color(white: 0.5))
                .opacity(0.55)

            Text("Type a .onion address in the address bar to begin.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var ipHiddenRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .bold))
            Text("Your IP is hidden via Tor").font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(TorPillTheme.green)
    }

    private var subtitle: String {
        switch tor.status {
        case .running: return "Connected"
        case .bootstrapping(let p): return p > 0 ? "Building circuit… \(p)%" : "Building circuit…"
        case .stopping: return "Stopping…"
        case .error(let m): return m
        case .stopped: return "Not connected"
        }
    }
}

// MARK: - Circuit visualization

/// A vertical "timeline" of the Tor route: this device → relays → the onion destination.
/// Uses live relay data (country + nickname) from the control port when available, otherwise a
/// representative diagram.
private struct TorCircuitView: View {
    let relays: [TorRelay]
    let destinationHost: String?
    let tint: Color

    private struct Hop {
        let label: String
        let sub: String
    }

    private var hops: [Hop] {
        var result = [Hop(label: "This device", sub: "Searxly")]
        if relays.isEmpty {
            // Fallback: representative 3-hop path (control port unavailable).
            result += [
                Hop(label: "Guard relay", sub: "Entry into Tor"),
                Hop(label: "Middle relay", sub: "Tor network"),
                Hop(label: "Rendezvous", sub: "Meeting point")
            ]
        } else {
            for (i, r) in relays.enumerated() {
                let role = i == 0 ? "Entry" : (i == relays.count - 1 ? "Exit" : "Middle")
                let place = r.countryCode == "??" ? role : "\(r.flag) \(r.countryCode) · \(role)"
                result.append(Hop(label: place, sub: r.nickname.isEmpty ? "Tor relay" : r.nickname))
            }
        }
        result.append(Hop(label: destinationHost ?? "Onion service", sub: "Tor hidden service"))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hops.enumerated()), id: \.offset) { idx, hop in
                HStack(alignment: .center, spacing: 11) {
                    node(isFirst: idx == 0, isLast: idx == hops.count - 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hop.label)
                            .font(.system(size: 11.5, weight: (idx == 0 || idx == hops.count - 1) ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(hop.sub)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 34)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func node(isFirst: Bool, isLast: Bool) -> some View {
        let line = tint.opacity(0.45)
        return VStack(spacing: 0) {
            Rectangle().fill(isFirst ? Color.clear : line).frame(width: 1.5, height: 16)
            Circle()
                .fill(tint.opacity(isFirst || isLast ? 1 : 0.8))
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: tint.opacity(0.6), radius: isFirst || isLast ? 3 : 0)
            Rectangle().fill(isLast ? Color.clear : line).frame(width: 1.5, height: 16)
        }
        .frame(width: 12)
    }
}

private enum TorPillTheme {
    static let canvas = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let green = SERPDesign.accentGreen
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.28)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.45)
}
