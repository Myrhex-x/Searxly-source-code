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
            Check(id: "filevault",   title: "Disk encrypted at rest (FileVault)", state: .pending, detail: ""),
        ]
        // FileVault: the app can't scrub what the OS writes outside its container (crash reports,
        // the quarantine DB) — disk encryption at rest is what keeps those unreadable if the machine
        // is lost. An OS setting, not an app defect, so "off" warns rather than fails.
        switch AntiForensics.dataVolumeEncrypted() {
        case true?:
            set("filevault", .pass, "The data volume is encrypted at rest — OS-side traces (crash logs, quarantine records) are unreadable without your login.")
        case false?:
            set("filevault", .warn, "FileVault is OFF. Anyone with the disk can read OS-side traces this app can't scrub. Turn it on in System Settings → Privacy & Security.")
        case nil:
            set("filevault", .warn, "Couldn't determine the disk's encryption state — check FileVault in System Settings → Privacy & Security.")
        }

        // Searxly Maximum edition extra checks: security-level enforcement (live-probed) and
        // supply-chain runtime verification.
        if Edition.isMaximum {
            checks.append(Check(id: "engine", title: "Security level enforced in the engine", state: .pending, detail: ""))
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

        // 6 + 7 (+ engine). Behavioral probe: build a scratch web view through the same factory path as
        // a real tab, load a blank in-memory page (no network), and check what a page's JS actually
        // sees — instead of passing these because the hardening was merely configured.
        if isMax {
            set("fingerprint", .running, "Probing a live web view…")
            set("webrtc", .running, "Probing a live web view…")
            if let obs = await EngineHardeningProbe.observe() {
                set("webrtc", obs.webrtcAbsent ? .pass : .fail,
                    obs.webrtcAbsent ? "Verified live: a page can't reach RTCPeerConnection, so WebRTC can't reveal your IP around Tor."
                                     : "A page can still construct RTCPeerConnection — WebRTC hardening is NOT reaching new tabs.")

                // Timezone (UTC) masking applies to every Maximum tab. The rest — an emptied plugin list,
                // a pinned CPU-core count, locale pinning, voice hiding, timer coarsening and
                // SharedArrayBuffer removal — are Searxly Maximum EDITION extras, deliberately withheld
                // from the base app so the edition is a real fingerprint upgrade.
                var leaks: [String] = []
                if obs.timezoneOffset != 0 { leaks.append("timezone (offset \(obs.timezoneOffset))") }
                if Edition.isMaximum {
                    if !obs.pluginsEmpty { leaks.append("plugin list") }
                    if obs.cores != 8 { leaks.append("CPU core count (\(obs.cores))") }
                    if obs.language != "en-US" { leaks.append("locale (\(obs.language))") }
                    if !obs.voicesEmpty { leaks.append("speech-voice list") }
                    if !obs.timerCoarsened { leaks.append("high-resolution timer") }
                    if !obs.sharedArrayBufferAbsent { leaks.append("SharedArrayBuffer") }
                }
                set("fingerprint", leaks.isEmpty ? .pass : .fail,
                    leaks.isEmpty ? "Verified live: timezone masked to UTC"
                                    + (Edition.isMaximum ? ", plugin list emptied, CPU cores pinned to 8, locale pinned to en-US, voices hidden, timer coarsened to 100 ms, SharedArrayBuffer gone." : ".")
                                  : "A page can still read: \(leaks.joined(separator: ", ")).")

                // Security-level enforcement (Searxly Maximum): at Safer/Safest the GPU + WASM exploit
                // surface must be unreachable; at Standard it is intentionally available (farbled).
                if Edition.isMaximum {
                    let level = MaximumSecurity.effective
                    if level == .standard {
                        set("engine", .pass, "Standard level: WebGL/WASM intentionally available; readbacks stay scrambled. Raise the level in Settings to drop them.")
                    } else {
                        var reachable: [String] = []
                        if obs.webglAvailable { reachable.append("WebGL") }
                        if obs.wasmAvailable { reachable.append("WebAssembly") }
                        set("engine", reachable.isEmpty ? .pass : .fail,
                            reachable.isEmpty ? "Verified live at \(level.displayName): WebGL and WebAssembly are unreachable in the engine."
                                              : "\(level.displayName) is set, but a page can still reach \(reachable.joined(separator: " and ")).")
                    }
                }
            } else {
                let msg = "Couldn't run the live engine probe — no verdict rather than a blind pass. Re-run the test."
                set("fingerprint", .warn, msg)
                set("webrtc", .warn, msg)
                if Edition.isMaximum { set("engine", .warn, msg) }
            }
        } else {
            set("fingerprint", .warn, "Strict fingerprint scrambling only runs in Maximum Privacy.")
            set("webrtc", .warn, "WebRTC hardening applies to Maximum + Tor tabs.")
            if Edition.isMaximum { set("engine", .warn, "The live probe only runs in Maximum Privacy.") }
        }

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
