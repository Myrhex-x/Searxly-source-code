//
//  NetworkEgressLedger.swift
//  Searxly
//
//  A live, in-memory record of how Searxly's own outbound traffic leaves the device, so the
//  "nothing leaks" promise of Maximum Privacy is VERIFIABLE rather than taken on faith. This is the
//  data model behind the in-app Network Ledger (Settings → Privacy) and complements PrivacyGate: the
//  gate DECIDES each request's fate, this records what it decided so the user can watch it.
//
//  Scope: it observes Searxly's native fetches and web navigations at the same choke points the kill
//  switch guards (PrivacyGate, TorLane, the navigation delegate). It is NOT a system-wide packet
//  monitor — it can't see other apps, and within a WKWebView it sees the top-level navigation, not
//  every sub-resource (those all ride the same per-tab Tor SOCKS proxy, so the lane is identical).
//
//  Privacy of the ledger itself: RAM-only, capped ring buffer, never written to disk and never sent
//  anywhere. It records the destination host of the user's OWN traffic purely to show it back to
//  them; it's cleared on quit (and in Amnesic mode nothing persists at all).
//

import Foundation
import Observation

/// How one outbound request left the device (or didn't).
enum EgressLane: String, Sendable, CaseIterable {
    case tor         // Bundled Tor client, SOCKS5h — hostnames resolve at the proxy, no DNS leak.
    case loopback    // Loopback SearXNG search lane; its UPSTREAM engine traffic is verified Tor-routed.
    case vpn         // Whole-device Searxly VPN tunnel.
    case direct      // Plain clearnet session. Only ever happens OUTSIDE Maximum Privacy.
    case blocked     // Fail-closed by the kill switch — the request never left the device.
    case suppressed  // A feature declined to make the request in Maximum (e.g. favicon → monogram).

    var label: String {
        switch self {
        case .tor:        return "Tor"
        case .loopback:   return "Local search"
        case .vpn:        return "VPN tunnel"
        case .direct:     return "Direct"
        case .blocked:    return "Blocked"
        case .suppressed: return "Suppressed"
        }
    }

    /// True when this lane hides the real IP (or never left the device at all).
    var isProtected: Bool {
        switch self {
        case .tor, .loopback, .vpn, .blocked, .suppressed: return true
        case .direct: return false
        }
    }

    var symbol: String {
        switch self {
        case .tor:            return "point.3.connected.trianglepath.dotted"
        case .loopback:       return "magnifyingglass"
        case .vpn:            return "network.badge.shield.half.filled"
        case .direct:         return "globe"
        case .blocked:        return "hand.raised.slash"
        case .suppressed:     return "eye.slash"
        }
    }
}

/// One recorded outbound event.
struct EgressEvent: Identifiable, Sendable {
    let id = UUID()
    let at: Date
    let host: String
    let lane: EgressLane
    /// Short category of the request, e.g. "page", "search", "image", "update-check".
    let kind: String
}

/// The live status of one class of Searxly traffic right now (drives the ledger's status header).
struct EgressLaneStatus: Identifiable {
    let id: String        // e.g. "Web pages"
    let lane: EgressLane
    let detail: String
}

@MainActor
@Observable
final class NetworkEgressLedger {
    static let shared = NetworkEgressLedger()

    private(set) var events: [EgressEvent] = []
    private let maxEvents = 300

    private init() {}

    // MARK: - Recording

    /// Append an event. Callable from any thread/actor via the nonisolated `record` shim below.
    func append(host: String, lane: EgressLane, kind: String) {
        // Collapse immediate duplicates (same host+lane+kind within 1s) so a burst of sub-requests
        // to one host doesn't flood the log — bump the timestamp instead.
        if let last = events.last, last.host == host, last.lane == lane, last.kind == kind,
           Date().timeIntervalSince(last.at) < 1.0 {
            events[events.count - 1] = EgressEvent(at: Date(), host: host, lane: lane, kind: kind)
            return
        }
        events.append(EgressEvent(at: Date(), host: host, lane: lane, kind: kind))
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    /// Thread-safe recording shim for the nonisolated gate/lane choke points. Hops onto the main
    /// actor; cheap and fire-and-forget (a ledger tolerates one-tick reordering).
    nonisolated static func record(host: String?, lane: EgressLane, kind: String) {
        guard Edition.isMaximum else { return }   // Network Ledger is a Searxly Maximum edition feature.
        let h = Self.normalizedHost(host)
        Task { @MainActor in NetworkEgressLedger.shared.append(host: h, lane: lane, kind: kind) }
    }

    /// Normalizes a host for display: strips a leading `www.`, maps loopback forms to "local search".
    nonisolated static func normalizedHost(_ host: String?) -> String {
        guard let raw = host?.lowercased(), !raw.isEmpty else { return "—" }
        if raw == "127.0.0.1" || raw == "localhost" || raw == "::1" { return "local search" }
        return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    /// Records a web navigation, deriving the lane from the current privacy posture. Called from the
    /// navigation delegate when a main-frame http(s) navigation proceeds. Loopback (local SearXNG UI /
    /// new-tab) navigations are skipped — they aren't egress.
    nonisolated static func recordWebNavigation(url: URL, isOnionTab: Bool) {
        guard Edition.isMaximum else { return }   // Network Ledger is a Searxly Maximum edition feature.
        let host = normalizedHost(url.host)
        Task { @MainActor in NetworkEgressLedger.shared.appendWebNavigation(host: host, isOnionTab: isOnionTab) }
    }

    private func appendWebNavigation(host: String, isOnionTab: Bool) {
        guard host != "—", host != "local search" else { return }
        let lane: EgressLane
        if isOnionTab {
            lane = .tor   // onion tabs are proxy-only — always over Tor
        } else {
            let privacy = PrivacyManager.shared
            switch (privacy.appPrivacyMode, privacy.maxProtection) {
            case (.maximum, .tor): lane = TorManager.shared.isRunning ? .tor : .blocked
            case (.maximum, .vpn): lane = SystemVPNManager.shared.isConnected ? .vpn : .blocked
            default:               lane = .direct
            }
        }
        append(host: host, lane: lane, kind: isOnionTab ? "onion" : "page")
    }

    func clear() { events.removeAll() }

    // MARK: - Live lane status (computed from the current privacy posture)

    /// A snapshot of where each class of Searxly traffic goes right now. Meaningful in Maximum
    /// Privacy; outside it, everything is a normal `direct` session.
    var liveLanes: [EgressLaneStatus] {
        let privacy = PrivacyManager.shared
        guard privacy.appPrivacyMode == .maximum else {
            return [EgressLaneStatus(id: "All traffic", lane: .direct,
                                     detail: "Standard browsing — Maximum Privacy is off.")]
        }

        switch privacy.maxProtection {
        case .tor:
            let torUp = TorManager.shared.isRunning
            let searchUp = torUp && LocalSearxngManager.shared.torSearchRouted
            return [
                EgressLaneStatus(id: "Web pages", lane: torUp ? .tor : .blocked,
                                 detail: torUp ? "Every tab via Tor SOCKS5h (no DNS leak)."
                                               : "Blocked until Tor finishes connecting."),
                EgressLaneStatus(id: "Local search", lane: searchUp ? .loopback : .blocked,
                                 detail: searchUp ? "Loopback only; SearXNG's upstream exits through Tor."
                                                  : "Blocked until search upstream is Tor-routed."),
                EgressLaneStatus(id: "Native fetches", lane: torUp ? .tor : .blocked,
                                 detail: torUp ? "Anonymous fetches ride Tor; identity-bearing calls stay blocked."
                                               : "Blocked until Tor is up."),
                EgressLaneStatus(id: "Favicons & updates", lane: .suppressed,
                                 detail: "Not issued in Maximum — shown as monograms; update checks paused.")
            ]
        case .vpn:
            let up = SystemVPNManager.shared.isConnected
            return [
                EgressLaneStatus(id: "All traffic", lane: up ? .vpn : .blocked,
                                 detail: up ? "Whole-device Searxly VPN tunnel."
                                            : "Blocked until the VPN tunnel is verified up.")
            ]
        }
    }

    /// Count of recorded events that did NOT hide the real IP (should be 0 in Maximum Privacy).
    var leakedCount: Int { events.lazy.filter { !$0.lane.isProtected }.count }
}
