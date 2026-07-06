//
//  AppPrivacyMode.swift
//  Searxly
//
//  App-level privacy posture, distinct from the per-tab `TabPrivacyMode` (standard/private/onion).
//  This is a persistent LADDER the whole app sits in, surfaced as one picker in Settings:
//
//    .normal     — fast, private defaults (tracker blocking, WebKit partitioning, HTTPS-only, the
//                  always-on Tier-1 fingerprint reductions in WebViewFactory). No behaviour change
//                  from how Searxly shipped.
//    .encrypted  — everything in .normal PLUS local at-rest lockdown (encryption + App Lock + no
//                  history). Implemented by reusing PrivacyManager.enableSecureMacPreset().
//    .maximum    — everything in .encrypted PLUS web/network anonymity: a fail-closed IP kill switch
//                  (requires a verified VPN or Tor — see PrivacyGate) and the full Strict fingerprint
//                  cluster injected by WebViewFactory. Implemented on top of enableStrictPrivacyMode().
//
//  The ladder is intentional: a Maximum-Privacy user also wants at-rest encryption, so each rung is a
//  superset of the one below. The breakage-prone protections (farbling, kill switch) live ONLY in
//  .maximum, so users who didn't opt in never pay for them.
//

import Foundation

/// The persistent, app-wide privacy posture. Stored in AppData and mirrored on PrivacyManager.
enum AppPrivacyMode: String, Codable, CaseIterable, Sendable {
    case normal
    case encrypted
    case maximum

    var displayName: String {
        switch self {
        case .normal:    return "Normal"
        case .encrypted: return "Encrypted"
        case .maximum:   return "Maximum Privacy"
        }
    }

    /// One-line, honest description for the Settings picker. Deliberately does NOT promise perfect
    /// anonymity — Maximum is "very hard to track," bounded by the WKWebView fingerprinting ceiling.
    var summary: String {
        switch self {
        case .normal:
            return "Fast and private. Blocks trackers, partitions site data, forces HTTPS."
        case .encrypted:
            return "Everything in Normal, plus your data on this Mac is encrypted and locked behind App Lock."
        case .maximum:
            return "Everything in Encrypted, plus your IP is hidden behind a VPN or Tor (or traffic is blocked) and your browser fingerprint is scrambled. Some sites may break."
        }
    }

    var systemImage: String {
        switch self {
        case .normal:    return "globe"
        case .encrypted: return "lock.fill"
        case .maximum:   return "shield.lefthalf.filled"
        }
    }

    /// True when this rung engages the fail-closed kill switch + Strict fingerprint cluster.
    var isMaximum: Bool { self == .maximum }
}

/// Which protection network Maximum Privacy enforces. The user picks this on entering Maximum; the
/// kill switch (PrivacyGate) blocks all of Searxly's traffic whenever the chosen network isn't
/// verified up. External/3rd-party VPNs are intentionally NOT offered yet — their state can only be
/// detected heuristically, which would weaken the guarantee.
enum MaxProtection: String, Codable, CaseIterable, Sendable {
    /// Searxly's managed VPN (SystemVPNManager / NEVPNManager). Fast, keeps search quality, but you
    /// trust our exit node.
    case vpn
    /// The bundled Tor client (TorManager). Trustless and free; slower, and some websites refuse
    /// Tor exits — search itself is Tor-routed (SearXNG outgoing socks5h) and works.
    case tor

    var displayName: String {
        switch self {
        case .vpn: return "Searxly VPN"
        case .tor: return "Tor"
        }
    }

    var summary: String {
        switch self {
        case .vpn: return "Fast. Hides your IP from websites — but our exit node sees your traffic."
        // Search is routed through Tor and works (SearXNG outgoing socks5h since 2026-07); the
        // honest caveat left is that some WEBSITES refuse Tor exit IPs.
        case .tor: return "Trustless and free. Slower, and some websites block Tor — search still works."
        }
    }

    var systemImage: String {
        switch self {
        case .vpn: return "network.badge.shield.half.filled"
        case .tor: return "point.3.connected.trianglepath.dotted"
        }
    }
}
