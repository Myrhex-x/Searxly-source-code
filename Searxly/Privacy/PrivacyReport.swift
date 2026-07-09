//
//  PrivacyReport.swift
//  Searxly
//
//  A point-in-time snapshot of Searxly's privacy posture, turned into a simple 0–100 score plus the
//  list of protections behind it — the data model for the standalone Privacy Report pane in Settings.
//
//  Honest by design. It is built ONLY from protections the app can actually attest to (private search,
//  IP routing, at-rest encryption, ad/tracker blocking, HTTPS enforcement, fingerprinting, history)
//  plus the real, live Network Egress Ledger. It deliberately does NOT invent a "trackers blocked"
//  tally: WebKit's content-rule-list blocking runs in the network process and reports no counts back,
//  so any such number would be guesswork (same reason PrivacyStatusView omits it).
//

import Foundation

@MainActor
struct PrivacyReport {

    /// One protection Searxly can attest to, and whether it's currently active. `weight` is its share
    /// of the 100-point posture score — the more a protection matters, the more it moves the needle.
    struct Protection: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let active: Bool
        let weight: Int
    }

    let protections: [Protection]

    // Session network activity, summarized from the live egress ledger.
    let observedRequests: Int   // total outbound events the ledger saw this session
    let protectedRequests: Int  // rode a hidden lane (VPN / Tor / local search / blocked / suppressed)
    let directRequests: Int     // left the device directly — those sites saw the real IP
    let filterListsActive: Int

    /// How this session's requests were routed, by lane, most-used first (empty lanes omitted).
    let laneBreakdown: [(lane: EgressLane, count: Int)]

    /// 0–100 posture score: the share of protection weight that's currently active.
    var score: Int {
        let total = protections.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let earned = protections.filter(\.active).reduce(0) { $0 + $1.weight }
        return Int((Double(earned) / Double(total) * 100).rounded())
    }

    var grade: String {
        switch score {
        case 85...:   return "A"
        case 70..<85: return "B"
        case 50..<70: return "C"
        default:      return "D"
        }
    }

    var verdict: String {
        switch score {
        case 85...:   return "Excellent — strong, layered privacy."
        case 70..<85: return "Strong — you're well protected."
        case 50..<70: return "Good — a few protections left to turn on."
        default:      return "Basic — turn on more protections below."
        }
    }

    var activeCount: Int { protections.filter(\.active).count }

    /// Builds a fresh report from the live managers.
    static func current() -> PrivacyReport {
        let privacy = PrivacyManager.shared
        let adblock = AdBlockManager.shared
        let ledger = NetworkEgressLedger.shared

        let vpnUp = SystemVPNManager.shared.isConnected
        // Traffic is routed over Tor when the user is on the Tor protection lane and Tor is up (and in
        // Searxly Maximum, which is permanently Tor-routed).
        let torUp = TorManager.shared.isRunning
        let torActive = torUp && (Edition.isMaximum || (privacy.appPrivacyMode == .maximum && privacy.maxProtection == .tor))
        let ipProtected = vpnUp || torActive

        let lists = adblock.activeCompiledListsCount
        let historyOn = PrivacyManager.shouldRecordHistory()
        let fingerprintOn = Edition.isMaximum || privacy.appPrivacyMode == .maximum

        var items: [Protection] = []

        items.append(.init(
            id: "search", title: "Private search",
            detail: "Queries are answered by your own SearXNG instance and never leave this Mac.",
            systemImage: "magnifyingglass", active: true, weight: 20))

        let ipDetail: String
        if vpnUp {
            ipDetail = "Your real IP is hidden behind the Searxly VPN."
        } else if torActive {
            ipDetail = "Your real IP is hidden behind Tor."
        } else if Edition.isMaximum {
            ipDetail = "Connecting to Tor to hide your IP…"
        } else {
            ipDetail = "Sites can see your real IP. Turn on the Searxly VPN to route your traffic through an encrypted tunnel."
        }
        items.append(.init(
            id: "ip", title: "IP address hidden",
            detail: ipDetail,
            systemImage: "eye.slash.fill", active: ipProtected, weight: 25))

        items.append(.init(
            id: "encryption", title: "Encrypted storage",
            detail: privacy.dataEncryptionEnabled
                ? "History, bookmarks, and settings are encrypted at rest on this Mac."
                : "Off — turn on encryption so your data is protected at rest.",
            systemImage: "externaldrive.fill.badge.checkmark", active: privacy.dataEncryptionEnabled, weight: 15))

        items.append(.init(
            id: "adblock", title: "Ad & tracker blocking",
            detail: adblock.isEnabled
                ? "Blocking known ad and tracker requests with \(lists) filter list\(lists == 1 ? "" : "s")."
                : "Off — turn it on to strip ads and trackers as pages load.",
            systemImage: "hand.raised.slash.fill", active: adblock.isEnabled, weight: 15))

        items.append(.init(
            id: "https", title: "HTTPS enforced",
            detail: "The open web is loaded over encrypted HTTPS connections only.",
            systemImage: "lock.fill", active: true, weight: 10))

        items.append(.init(
            id: "fingerprint", title: "Fingerprint scrambling",
            detail: fingerprintOn
                ? "Your browser fingerprint is scrambled — canvas, WebGL, and fonts — so sites can't identify you across visits."
                : "Not active — your browser fingerprint is visible, which lets sites recognize you across visits.",
            systemImage: "touchid", active: fingerprintOn, weight: 10))

        items.append(.init(
            id: "history", title: "No browsing history",
            detail: historyOn
                ? "History is being saved on this Mac. Turn it off to keep nothing."
                : "Searxly isn't saving any browsing history.",
            systemImage: "clock.arrow.circlepath", active: !historyOn, weight: 5))

        let events = ledger.events
        let observed = events.count
        let direct = events.lazy.filter { !$0.lane.isProtected }.count

        let laneCounts = Dictionary(grouping: events, by: \.lane).mapValues(\.count)
        let breakdown = EgressLane.allCases
            .compactMap { lane -> (lane: EgressLane, count: Int)? in
                guard let c = laneCounts[lane], c > 0 else { return nil }
                return (lane, c)
            }
            .sorted { $0.count > $1.count }

        return PrivacyReport(
            protections: items,
            observedRequests: observed,
            protectedRequests: observed - direct,
            directRequests: direct,
            filterListsActive: lists,
            laneBreakdown: breakdown
        )
    }
}
