//
//  TorManager.swift
//  Searxly
//
//  In-app control of the bundled Tor client used to reach `.onion` services. Tor runs as a native
//  process supervised by the unsandboxed SearxlyHelper, started lazily on the first onion tab.
//  Onion-only: only `.onion` tabs route through Tor. Not Tor Browser — hides the IP and reaches
//  onions, but does not replicate Tor Browser's anti-fingerprinting.
//

import Foundation
import SwiftUI
import Observation
import os

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

    /// Whether onion routing is turned on. Off by default — the user opts in (Settings, onboarding, or
    /// the "Enable Tor?" prompt the first time they open a .onion). Disabling stops any running Tor.
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: "Tor.Enabled") {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "Tor.Enabled")
            if !isEnabled {
                Task { await stop() }
                // Let open onion tabs react — they can no longer reach their hidden service.
                NotificationCenter.default.post(name: .torDisabled, object: nil)
            }
        }
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

    var socksHost: String { TorRuntimeConfig.socksHost }
    var socksPort: UInt16 { TorRuntimeConfig.socksPort }

    var isRunning: Bool { status == .running }
    var bundledVersion: String { TorRuntimeConfig.bundledVersion }

    private init() {}

    // MARK: - Bundle paths (Resources/tor-runtime/, defensive Bundle.main lookups)

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

    /// False when no Tor binary is bundled — onion support is unavailable.
    var isAvailable: Bool { bundledTorBinaryPath != nil }

    // MARK: - Lifecycle

    /// Ensures Tor is running and bootstrapped. Returns true once a circuit is ready.
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

    /// SIGNAL NEWNYM then refresh the displayed path. The caller should reload the active onion tab
    /// so its next request uses the new circuit.
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
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshCircuit()
        }
        return true
    }

    /// Onion tabs aren't restored across launches, so any Tor alive at startup is stale — reap it.
    func cleanupStaleAtLaunch() async {
        guard let proxy = HelperClient.shared.proxy() else { return }
        if await proxy.isTorRunningAsync() {
            _ = await proxy.stopTorAsync()
            status = .stopped
            log("Reaped a stale Tor process from a previous run.")
        }
    }

    // MARK: - Bootstrap polling

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
