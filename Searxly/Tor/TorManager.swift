//
//  TorManager.swift
//  Searxly
//
//  First-class in-app control of a private, bundled Tor client used to reach `.onion` hidden
//  services. Tor runs as a bundled native process supervised by the unsandboxed SearxlyHelper XPC
//  service — the same model as the local SearXNG runtime (see LocalSearxngManager).
//
//  Scope (v1): onion-only. Only `.onion` tabs route through Tor (via a per-data-store SOCKS5 proxy
//  in WebViewFactory). Normal browsing is untouched. Tor is started lazily on the first onion tab.
//
//  HONESTY: this provides network-level anonymity (real IP hidden, .onion reachable, no DNS leak)
//  but is NOT Tor Browser — it does not replicate Tor Browser's anti-fingerprinting. Surface that
//  to the user wherever onion support is advertised.
//

import Foundation
import SwiftUI
import Observation
import os   // os.Logger string interpolation (privacy:) used by Log.tor

@Observable
@MainActor
final class TorManager {
    static let shared = TorManager()

    enum Status: Equatable {
        case stopped
        case bootstrapping(Int)   // 0...100
        case running
        case stopping
        case error(String)
    }

    private(set) var status: Status = .stopped
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var logs: [String] = []

    /// Relays of the live Tor circuit (entry → middle → exit), from the control port. Empty when the
    /// control port is unavailable — the UI falls back to a representative diagram.
    private(set) var circuit: [TorRelay] = []

    /// True while a "new circuit" request is in flight — drives the pill's progress feedback.
    private(set) var rebuilding = false

    /// SOCKS5 endpoint that onion tabs proxy through (see TorRuntimeConfig).
    var socksHost: String { TorRuntimeConfig.socksHost }
    var socksPort: UInt16 { TorRuntimeConfig.socksPort }

    var isRunning: Bool { status == .running }

    /// The bundled Tor version (for display in Settings).
    var bundledVersion: String { TorRuntimeConfig.bundledVersion }

    private init() {}

    // MARK: - Bundle paths
    //
    // Shipped read-only at Searxly.app/Contents/Resources/tor-runtime/. Resolved with defensive
    // Bundle.main lookups (flat + subdir) so it works regardless of how the folder reference landed,
    // exactly like LocalSearxngManager.bundledRuntimePythonPath.

    var bundledTorBinaryPath: String? { bundledResource(named: "tor") }
    var bundledGeoIPPath: String? { bundledResource(named: "geoip") }
    var bundledGeoIP6Path: String? { bundledResource(named: "geoip6") }

    private func bundledResource(named name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "tor-runtime") {
            return url.path
        }
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("tor-runtime/\(name)").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// True when a usable Tor binary is bundled. When false, onion support is unavailable and the UI
    /// should say so rather than failing silently.
    var isAvailable: Bool { bundledTorBinaryPath != nil }

    // MARK: - Lifecycle

    /// Ensures Tor is running and fully bootstrapped. Called before loading the first `.onion` URL.
    /// Returns true once a circuit is ready.
    @discardableResult
    func ensureReadyAndRunning() async -> Bool {
        if status == .running { return true }
        return await start()
    }

    @discardableResult
    func start() async -> Bool {
        if status == .running { return true }
        guard !isBusy else { return false }

        guard let torPath = bundledTorBinaryPath else {
            setError("Tor runtime is missing from the app (Resources/tor-runtime/tor). Run scripts/fetch-tor-runtime.sh and add the folder to the Searxly target.")
            return false
        }

        isBusy = true
        lastError = nil
        status = .bootstrapping(0)
        log("▶️ Starting Tor (bundled runtime)…")

        guard let proxy = HelperClient.shared.proxy() else {
            isBusy = false
            setError("Helper service unavailable.")
            return false
        }

        let (pid, err): (Int32, String) = await proxy.startTorAsync(
            torBinaryPath: torPath,
            geoipPath: bundledGeoIPPath ?? "",
            geoip6Path: bundledGeoIP6Path ?? "",
            socksPort: Int32(socksPort)
        )

        if pid <= 0 {
            isBusy = false
            setError(err.isEmpty ? "Failed to start Tor." : err)
            return false
        }
        log("   Tor launched (pid \(pid)). Bootstrapping a circuit (first run can take 10–30s)…")

        let ok = await waitForBootstrap(maxAttempts: 60, delaySeconds: 1)
        isBusy = false

        if ok {
            status = .running
            lastError = nil
            log("✅ Tor connected.")
            await refreshCircuit()
            return true
        } else {
            setError("Tor started but did not finish bootstrapping. See ~/Library/Application Support/Searxly/tor/tor.log.")
            return false
        }
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        status = .stopping
        log("⏹ Stopping Tor…")
        _ = await HelperClient.shared.proxy()?.stopTorAsync()
        isBusy = false
        status = .stopped
        circuit = []
        log("   Tor stopped.")
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - Live circuit (control port)

    /// Refreshes `circuit` from Tor's control port. No-op (clears) when Tor isn't running.
    func refreshCircuit() async {
        guard status == .running else { circuit = []; return }
        guard let data = await HelperClient.shared.proxy()?.torControlCircuitAsync(),
              let relays = try? JSONDecoder().decode([TorRelay].self, from: data) else { return }
        circuit = relays
    }

    /// Requests a fresh Tor circuit (SIGNAL NEWNYM) and refreshes the displayed path. The caller
    /// should reload the active onion tab so its next request uses the new circuit.
    @discardableResult
    func newCircuit() async -> Bool {
        guard status == .running, !rebuilding else { return false }
        rebuilding = true
        defer { rebuilding = false }

        guard let ok = await HelperClient.shared.proxy()?.torNewIdentityAsync(), ok else {
            log("⚠️ New circuit request failed (Tor control port unavailable).")
            return false
        }
        log("Requested a new Tor circuit (NEWNYM).")
        // Give Tor a moment to lay down fresh circuits, refreshing the displayed path as it changes.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshCircuit()
        }
        return true
    }

    /// Onion tabs are never restored across launches, so any Tor process alive at startup is stale
    /// (orphaned from a previous run whose helper was torn down). Reap it. Call once at launch.
    func cleanupStaleAtLaunch() async {
        guard let proxy = HelperClient.shared.proxy() else { return }
        if await proxy.isTorRunningAsync() {
            _ = await proxy.stopTorAsync()
            status = .stopped
            log("Reaped a stale Tor process from a previous run.")
        }
    }

    // MARK: - Bootstrap polling

    /// Polls the helper for Tor's bootstrap percentage until it reaches 100 or attempts run out.
    /// Mirrors LocalSearxngManager.waitForLocalWebReady's poll-only loop.
    private func waitForBootstrap(maxAttempts: Int, delaySeconds: UInt64) async -> Bool {
        for _ in 0..<maxAttempts {
            guard let proxy = HelperClient.shared.proxy() else { return false }
            let pct = await proxy.torBootstrapProgressAsync()
            if pct >= 100 {
                status = .bootstrapping(100)
                return true
            }
            if pct >= 0 {
                status = .bootstrapping(Int(pct))
            }
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }
        return false
    }

    // MARK: - Helpers

    private func setError(_ msg: String) {
        lastError = msg
        status = .error(msg)
        log("❌ " + msg)
    }

    private func log(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        Log.tor.info("\(line, privacy: .public)")
    }
}

/// One relay (hop) in a live Tor circuit, as reported by the control port.
struct TorRelay: Codable, Equatable, Identifiable {
    let nickname: String
    let country: String   // ISO 3166-1 alpha-2 (lowercase from Tor), or "" / "??" when unknown
    let ip: String

    var id: String { nickname + "|" + ip }

    /// Uppercased country code for display, or "??" when unknown.
    var countryCode: String {
        let c = country.uppercased()
        return (c.count == 2 && c != "??") ? c : "??"
    }

    /// Flag emoji for the country, or a neutral flag when unknown.
    var flag: String {
        let c = country.uppercased()
        guard c.count == 2, c != "??" else { return "🏴" }
        var s = ""
        for u in c.unicodeScalars {
            if let scalar = UnicodeScalar(127397 + u.value) { s.unicodeScalars.append(scalar) }
        }
        return s.isEmpty ? "🏴" : s
    }
}
