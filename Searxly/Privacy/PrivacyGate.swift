//
//  PrivacyGate.swift
//  Searxly
//
//  The fail-closed IP kill switch for Maximum Privacy mode.
//
//  Principle: a mode that promises "websites can't see your IP" must FAIL CLOSED — if the chosen
//  protection network (Searxly VPN or Tor) isn't verified up, Searxly's traffic is blocked rather
//  than silently leaking your real IP. The gate is INERT outside Maximum Privacy, so Normal/Encrypted
//  users are never affected.
//
//  Scope: this is a PER-APP kill switch — it gates Searxly's own web navigations and native fetches.
//  It is NOT a system-wide (Network-Extension) kill switch and does not touch other apps' traffic.
//
//  Enforcement points:
//    1. Web navigations — WebViewRepresentable+Navigation asks `shouldBlockWebNavigation(to:)` and
//       cancels + shows the blocked page when down.
//    2. Native fetches — three lanes:
//       a. Anonymous fetches (knowledge panel, thumbnails, AI page-fetch, wallet market data) use
//          `TorLane.current()`: the plain session when this gate is open, the bundled Tor client in
//          Maximum+Tor once Tor is up, fail-closed otherwise. See TorLane.swift.
//       b. Address-keyed / identity-bearing fetches (wallet RPC, explorer history) check
//          `assertEgressAllowed()` / `egressAllowedFast` and stay hard-blocked whenever this gate
//          is closed — no Tor substitution.
//       c. The LOCALHOST SearXNG search/autocomplete/image lane (`assertSearchEgressAllowed(to:)`):
//          the hop is loopback, but SearXNG then fetches upstream — so it's only allowed once that
//          upstream traffic is verified to exit through the protection network (VPN covers it
//          whole-device; in Tor mode LocalSearxngManager patches SearXNG's outgoing.proxies onto
//          Tor's SOCKS and confirms the running process uses it — see LocalSearxngManager+TorRouting).
//

import Foundation
import NetworkExtension
import Observation
import os

enum PrivacyGateError: LocalizedError {
    /// Maximum Privacy is on and the chosen protection network isn't up — the request was blocked.
    case blocked

    var errorDescription: String? {
        "Maximum Privacy blocked this request because your protection network (VPN or Tor) isn't connected yet. It will work automatically once protection is up."
    }
}

@MainActor
@Observable
final class PrivacyGate {
    static let shared = PrivacyGate()

    /// Posted (main thread) whenever the protected/blocked state flips, so the navigation layer can
    /// reload tabs that were blocked while protection was down, and any UI can refresh.
    static let protectionStateChangedNotification = Notification.Name("Searxly.ProtectionStateChanged")

    /// Lock-free snapshot of "is Searxly allowed to send traffic right now?", readable from any thread
    /// or actor (native fetches run on background tasks). Written only on the main actor when the state
    /// changes. A Bool word is atomically read/written on Apple platforms; a one-tick-stale read is
    /// harmless for a gate — the next check corrects it. Defaults to `true` so nothing is gated until
    /// Maximum Privacy is actually engaged.
    nonisolated(unsafe) private static var _egressAllowedCache = true

    /// Same lock-free pattern for the loopback SearXNG search lane (see `isLocalSearchProtected`).
    nonisolated(unsafe) private static var _localSearchAllowedCache = true

    /// Fast, synchronous, any-thread check used by native fetch guards.
    nonisolated static var egressAllowedFast: Bool { _egressAllowedCache }

    /// Fast, synchronous, any-thread check for the loopback SearXNG search/autocomplete fetches.
    nonisolated static var localSearchAllowedFast: Bool { _localSearchAllowedCache }

    private init() {
        // VPN connect/drop fires this system notification (SystemVPNManager observes it too).
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { _ in Task { @MainActor in PrivacyGate.shared.refresh() } }

        // Entering/leaving Maximum flips the gate on/off and (on entry) connects the chosen network.
        NotificationCenter.default.addObserver(
            forName: PrivacyManager.appPrivacyModeChangedNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in PrivacyGate.shared.onModeChanged() } }

        // Switching VPN ↔ Tor inside Maximum needs the same treatment: connect the new network and
        // re-route the local SearXNG's upstream traffic to match.
        NotificationCenter.default.addObserver(
            forName: PrivacyManager.maxProtectionChangedNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in PrivacyGate.shared.onModeChanged() } }

        observeTor()
        refresh()

        // If the app launches already in Maximum (persisted), bring the protection network up.
        if PrivacyManager.shared.appPrivacyMode == .maximum {
            Task { await ensureProtection() }
        }
    }

    // MARK: - State

    /// Whether WEB navigations are protected. Web traffic is routed in both modes — whole-device VPN,
    /// or Tor's per-tab SOCKS proxy (WebViewFactory.applyTorRouting) — so it's "protected" once the
    /// chosen network is up. Inert (true) outside Maximum Privacy.
    var isWebProtected: Bool {
        guard PrivacyManager.shared.appPrivacyMode == .maximum else { return true }
        switch PrivacyManager.shared.maxProtection {
        case .vpn: return SystemVPNManager.shared.isConnected
        case .tor: return TorManager.shared.isRunning
        }
    }

    /// Whether NATIVE fetches (page-fetch, knowledge panel, thumbnails) are protected. These ride
    /// `URLSession.shared`, which the whole-device VPN covers but Tor's per-tab SOCKS proxy does
    /// NOT — so in Tor mode external native egress is BLOCKED (fail closed) to avoid leaking the
    /// real IP; those features degrade gracefully. The loopback SearXNG search/autocomplete is the
    /// exception — it has its own lane (`isLocalSearchProtected`) because its upstream traffic can
    /// be routed through Tor inside SearXNG itself.
    var isNativeProtected: Bool {
        guard PrivacyManager.shared.appPrivacyMode == .maximum else { return true }
        switch PrivacyManager.shared.maxProtection {
        case .vpn: return SystemVPNManager.shared.isConnected
        case .tor: return false
        }
    }

    /// Whether the LOOPBACK SearXNG search/autocomplete fetches are protected. The hop itself is
    /// loopback; what matters is where SearXNG sends its upstream engine requests:
    ///   - VPN: the whole-device tunnel covers SearXNG's egress once connected.
    ///   - Tor: allowed only after LocalSearxngManager has patched `outgoing.proxies` onto Tor's
    ///     SOCKS endpoint AND verified the running process uses it (`torSearchRouted`) — until then,
    ///     fail closed.
    var isLocalSearchProtected: Bool {
        guard PrivacyManager.shared.appPrivacyMode == .maximum else { return true }
        switch PrivacyManager.shared.maxProtection {
        case .vpn: return SystemVPNManager.shared.isConnected
        case .tor: return TorManager.shared.isRunning && LocalSearxngManager.shared.torSearchRouted
        }
    }

    /// Tracks the web-protected state across refreshes so we can notify on either web or native change.
    private var lastWebProtected = true

    /// User-facing reason web traffic is blocked, or nil when allowed.
    var blockReason: String? {
        guard !isWebProtected else { return nil }
        switch PrivacyManager.shared.maxProtection {
        case .vpn:
            if !ManagedVPNService.shared.hasActivePass {
                // Maximum's included comp just lapsed and enforceAccess is already switching the lane back
                // to Tor, so say that rather than asking the user to fix it — browsing resumes by itself.
                // (A pass can be renewed in Settings → VPN in either edition.) The base app has no such
                // fallback: it sits on the lane the user chose, so it gets the actionable message.
                return Edition.isMaximum
                    ? "Your included VPN has ended — switching you back to Tor…"
                    : "Maximum Privacy needs an active VPN pass — buy one in Settings → VPN, or switch your protection to Tor in Settings → Privacy."
            }
            return "Connecting to the Searxly VPN… traffic stays blocked until your IP is hidden."
        case .tor:
            return "Connecting to Tor… traffic stays blocked until your IP is hidden."
        }
    }

    /// Recomputes the fast caches and notifies observers when web, native, or local-search protection
    /// changes.
    func refresh() {
        // Heal a common Maximum desync: the system VPN tunnel is up, but the kill switch is still
        // waiting on Tor (the default lane). That happens when the user connected the Searxly VPN
        // without flipping "Hide my IP with" to VPN — search and pages then fail with "VPN or Tor
        // isn't connected" even though VPN is live. Promote the live tunnel to the protection lane
        // so routing + gate agree. Don't interrupt an in-flight Tor bootstrap.
        if healVPNLaneDesyncIfNeeded() { return }

        let nativeAllowed = isNativeProtected
        let localSearchAllowed = isLocalSearchProtected
        let webAllowed = isWebProtected
        let changed = (nativeAllowed != Self._egressAllowedCache)
            || (localSearchAllowed != Self._localSearchAllowedCache)
            || (webAllowed != lastWebProtected)
        Self._egressAllowedCache = nativeAllowed
        Self._localSearchAllowedCache = localSearchAllowed
        lastWebProtected = webAllowed
        if changed {
            NotificationCenter.default.post(name: Self.protectionStateChangedNotification, object: nil)
            Log.privacy.info("PrivacyGate: web=\(webAllowed ? "ok" : "blocked", privacy: .public) native=\(nativeAllowed ? "ok" : "blocked", privacy: .public) localSearch=\(localSearchAllowed ? "ok" : "blocked", privacy: .public)")
        }
    }

    /// If Maximum is on the Tor lane, Tor is fully down, and the Searxly VPN tunnel is already
    /// connected, switch the kill switch to VPN. Returns true when it switched (caller should stop —
    /// `setMaxProtection` posts a notification that re-enters `refresh` via `onModeChanged`).
    @discardableResult
    private func healVPNLaneDesyncIfNeeded() -> Bool {
        guard Edition.isMaximum,
              PrivacyManager.shared.appPrivacyMode == .maximum,
              PrivacyManager.shared.maxProtection == .tor,
              SystemVPNManager.shared.isConnected else { return false }
        switch TorManager.shared.status {
        case .stopped, .error:
            break
        case .running, .bootstrapping, .stopping:
            return false
        @unknown default:
            return false
        }
        guard PrivacyManager.shared.canSelectVPNProtection else { return false }
        Log.privacy.info("PrivacyGate: live VPN tunnel while Tor is down — switching kill switch to VPN")
        PrivacyManager.shared.setMaxProtection(.vpn)
        return true
    }

    private func onModeChanged() {
        refresh()
        Task { await ensureProtection() }
    }

    /// Brings the chosen protection network up so the kill switch can open, and reconciles the local
    /// SearXNG's upstream routing with the mode (Tor-proxied in Maximum+Tor, direct otherwise). Safe
    /// to call repeatedly — the managers no-op when already in the right state. Note: the VPN path
    /// requires an active pass; if there isn't one, the VPN won't connect and the gate stays closed
    /// (blockReason explains how to proceed).
    ///
    /// `.onion` tabs are independent of this lane: `openOnionURL` always starts Tor for those, even
    /// while Maximum Privacy rides the VPN (clearnet on VPN, onion on Tor).
    func ensureProtection() async {
        if PrivacyManager.shared.appPrivacyMode == .maximum {
            switch PrivacyManager.shared.maxProtection {
            case .vpn:
                await SystemVPNManager.shared.connectSearxlyNode()
                // If the tunnel never came up (dead node, failed switch), stay fail-closed only for a
                // moment — flip to Tor so search isn't bricked. SystemVPNManager also does this; this
                // is the gate-side backstop after ensureProtection returns.
                if !SystemVPNManager.shared.isConnected {
                    Log.privacy.info("PrivacyGate: VPN lane requested but tunnel is down — falling back to Tor")
                    PrivacyManager.shared.setMaxProtection(.tor)
                    _ = await TorManager.shared.ensureReadyAndRunning()
                }
            case .tor:
                _ = await TorManager.shared.ensureReadyAndRunning()
            }
        }
        await LocalSearxngManager.shared.reconcileTorSearchRouting()
        refresh()
    }

    /// Re-arming Observation watcher on Tor's status so Tor connect/drop updates the gate. (The VPN
    /// path is driven by the NEVPNStatusDidChange notification instead.)
    private func observeTor() {
        withObservationTracking {
            _ = TorManager.shared.status
        } onChange: {
            Task { @MainActor in
                PrivacyGate.shared.refresh()
                PrivacyGate.shared.observeTor()
            }
        }
    }

    // MARK: - Native egress gate (any thread)

    /// Throwing guard for native URLSession fetches. In Maximum Privacy with protection down this
    /// throws `PrivacyGateError.blocked` so the request never leaves the device. Inert otherwise.
    nonisolated static func assertEgressAllowed() throws {
        if !egressAllowedFast { throw PrivacyGateError.blocked }
    }

    /// Throwing guard for the SearXNG search/autocomplete fetches. Loopback instances ride the
    /// local-search lane, which Tor mode opens once SearXNG's upstream is verified Tor-routed.
    /// A remote (non-loopback) instance is a plain clearnet fetch that would reveal the real IP to
    /// the instance host, so it falls back to the strict native gate — blocked in Tor mode.
    nonisolated static func assertSearchEgressAllowed(to url: URL?) throws {
        let host = url?.host?.lowercased() ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if isLoopback {
            if !localSearchAllowedFast {
                NetworkEgressLedger.record(host: url?.host, lane: .blocked, kind: "search")
                throw PrivacyGateError.blocked
            }
            NetworkEgressLedger.record(host: url?.host, lane: .loopback, kind: "search")
        } else {
            try assertEgressAllowed()
        }
    }

    // MARK: - Web egress gate (navigation delegate)

    /// Whether a web navigation to `url` must be blocked right now. Loopback (the local SearXNG UI
    /// shell, the new-tab page) and `about:` are always allowed — the actual upstream search is blocked
    /// at the native layer via `assertEgressAllowed()`. Only meaningful in Maximum Privacy.
    func shouldBlockWebNavigation(to url: URL?) -> Bool {
        guard PrivacyManager.shared.appPrivacyMode == .maximum, !isWebProtected else { return false }
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let host = url?.host?.lowercased() ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        return !isLoopback
    }
}
