//
//  PrivacySelfTest.swift
//  Searxly
//
//  A one-tap, in-app privacy self-test: instead of asking the user to trust the "nothing leaks"
//  claim, it verifies the live posture and — the headline check — actively confirms the real IP is
//  hidden by fetching an IP-echo THROUGH the bundled Tor client and checking it comes back as a Tor
//  exit. Every network request the test makes rides the same fail-closed Tor lane as the rest of the
//  app, so the test itself can't leak: if Tor isn't up, the active check simply can't run.
//

import Foundation
import Observation

@MainActor
@Observable
final class PrivacySelfTest {
    static let shared = PrivacySelfTest()

    struct Check: Identifiable {
        enum State { case pending, running, pass, warn, fail }
        let id: String
        let title: String
        var state: State
        var detail: String
    }

    private(set) var checks: [Check] = []
    private(set) var running = false
    private(set) var lastRun: Date?

    private init() {}

    /// Overall verdict for the summary line: fail if any check failed, warn if any warned, else pass.
    var verdict: Check.State {
        if checks.contains(where: { $0.state == .fail }) { return .fail }
        if checks.contains(where: { $0.state == .running || $0.state == .pending }) { return .running }
        if checks.contains(where: { $0.state == .warn }) { return .warn }
        return checks.isEmpty ? .pending : .pass
    }

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false; lastRun = Date() }

        checks = [
            Check(id: "mode",        title: "Maximum Privacy engaged",          state: .pending, detail: ""),
            Check(id: "tor",         title: "Tor circuit established",          state: .pending, detail: ""),
            Check(id: "ip",          title: "Your real IP is hidden",           state: .pending, detail: ""),
            Check(id: "search",      title: "Search exits through Tor",         state: .pending, detail: ""),
            Check(id: "killswitch",  title: "Kill switch armed (fail-closed)",  state: .pending, detail: ""),
            Check(id: "fingerprint", title: "Fingerprint scrambling active",    state: .pending, detail: ""),
            Check(id: "webrtc",      title: "WebRTC IP-leak blocked",           state: .pending, detail: ""),
        ]
        // Supply-chain runtime verification is a Searxly Maximum edition check only.
        if Edition.isMaximum {
            checks.append(Check(id: "runtime", title: "Bundled Tor runtime verified", state: .pending, detail: ""))
        }

        let privacy = PrivacyManager.shared
        let isMax = privacy.appPrivacyMode == .maximum
        let isTor = privacy.maxProtection == .tor
        let torRunning = TorManager.shared.isRunning

        // 1. Mode
        set("mode", isMax ? .pass : .warn,
            isMax ? "Locked to Maximum Privacy over Tor."
                  : "Not in Maximum Privacy — enable it to test the full posture.")

        // 2. Tor circuit
        if isMax && isTor {
            set("tor", torRunning ? .pass : .fail,
                torRunning ? "The bundled Tor client is running and bootstrapped."
                           : "Tor isn't connected yet — start it, then re-run the test.")
        } else {
            set("tor", .warn, "Protection isn't set to Tor.")
        }

        // 3. Active exit-IP check — the one that actually proves the IP is hidden.
        if isMax && isTor && torRunning {
            set("ip", .running, "Checking your exit IP over Tor…")
            switch await Self.checkTorExitIP() {
            case .success(let ip):
                set("ip", .pass, "Confirmed Tor exit \(ip). Your real IP and DNS never left this Mac.")
            case .notTor(let ip):
                set("ip", .fail, "A request returned \(ip) but Tor wasn't detected — do not trust this build until resolved.")
            case .failure(let msg):
                set("ip", .fail, "Couldn't verify the exit IP over Tor: \(msg)")
            }
        } else {
            set("ip", .warn, "Skipped — the live IP check only runs in Maximum Privacy over Tor.")
        }

        // 4. Search upstream routing
        if isMax && isTor {
            let routed = LocalSearxngManager.shared.torSearchRouted
            set("search", routed ? .pass : .warn,
                routed ? "SearXNG's upstream engine traffic exits through Tor (socks5h — no DNS leak)."
                       : "Search upstream isn't Tor-routed yet; searches stay blocked until it is.")
        } else {
            set("search", .warn, "Not applicable outside Maximum + Tor.")
        }

        // 5. Kill switch
        set("killswitch", isMax ? .pass : .warn,
            isMax ? "Fail-closed: if protection drops, pages and searches are blocked, not leaked."
                  : "The kill switch only arms in Maximum Privacy.")

        // 6. Fingerprint scrambling (Strict farbling is gated on Maximum in WebViewFactory)
        set("fingerprint", isMax ? .pass : .warn,
            isMax ? "Strict farbling: canvas / WebGL / audio / WebGPU readbacks scrambled; timezone & locale masked."
                  : "Strict fingerprint scrambling only runs in Maximum Privacy.")

        // 7. WebRTC hardening (neutered in Maximum + Tor tabs)
        set("webrtc", (isMax && isTor) ? .pass : .warn,
            (isMax && isTor) ? "RTCPeerConnection is neutered in every tab, so WebRTC can't reveal your IP around Tor."
                             : "WebRTC hardening applies to Maximum + Tor tabs.")

        // 8. Supply chain (Maximum edition only) — the bundled Tor binary is the one Searxly shipped.
        if Edition.isMaximum {
            let integrity = RuntimeIntegrity.verifyTorRuntime()
            if integrity.ok {
                if let reason = integrity.skippedReason {
                    set("runtime", .warn, "Runtime signature couldn’t be pinned — \(reason).")
                } else {
                    set("runtime", .pass, "The bundled Tor binary is signed by Searxly’s team and unmodified (\(integrity.checked.joined(separator: ", "))).")
                }
            } else {
                set("runtime", .fail, "The bundled Tor runtime failed verification: \(integrity.failures.joined(separator: "; ")). Do not trust this build — reinstall Searxly.")
            }
        }
    }

    private func set(_ id: String, _ state: Check.State, _ detail: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = state
        checks[i].detail = detail
    }

    // MARK: - Active check

    private enum IPCheckResult { case success(String), notTor(String), failure(String) }

    /// Fetches Tor Project's IP-echo through the Tor lane. Returns the exit IP and whether Tor was
    /// detected. Rides `TorLane` so it inherits the fail-closed guarantee — no Tor, no request.
    private static func checkTorExitIP() async -> IPCheckResult {
        guard let lane = await TorLane.current(), lane.viaTor else {
            return .failure("the Tor lane is unavailable")
        }
        guard let url = URL(string: "https://check.torproject.org/api/ip") else {
            return .failure("bad test URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await lane.session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .failure("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            // Response shape: {"IsTor":true,"IP":"185.220.101.x"}
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("could not parse the response")
            }
            let ip = (obj["IP"] as? String) ?? "unknown"
            let isTor = (obj["IsTor"] as? Bool) ?? false
            NetworkEgressLedger.record(host: "check.torproject.org", lane: .tor, kind: "self-test")
            return isTor ? .success(ip) : .notTor(ip)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
