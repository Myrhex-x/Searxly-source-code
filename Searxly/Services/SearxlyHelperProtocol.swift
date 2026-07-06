//
//  SearxlyHelperProtocol.swift
//  Shared — add to BOTH Searxly and SearxlyHelper targets in Xcode.
//
//  XPC interface between the Searxly main app (sandboxed) and the
//  SearxlyHelper XPC service (unsandboxed). The service supervises the bundled
//  native Python SearXNG process and performs ~/searxng-local file I/O on the app's behalf.
//

import Foundation

/// XPC interface between Searxly (main) and SearxlyHelper (XPC service, no sandbox).
///
/// Rules for adding methods:
///   - Use only NSXPCConnection-safe scalar types: String, Bool, Data, Int32.
///   - Collections must NOT appear as @objc parameters — pass them as JSON-encoded Data
///     (NSData is always whitelisted by XPC).
///   - Every method must have exactly one reply block as its last parameter.
///   - The reply block is called exactly once, even on error paths.
@objc protocol SearxlyHelperProtocol {

    // MARK: - SearXNG native process supervision

    /// Launches the bundled SearXNG as a child process: `<pythonExecutablePath> -m searx.webapp`,
    /// with `SEARXNG_SETTINGS_PATH=settingsPath`, `SEARXNG_BIND_ADDRESS=bindAddress`,
    /// `SEARXNG_PORT=port`. Writes a pidfile under ~/searxng-local so the process can be tracked
    /// even across XPC-service recycling. Idempotent: if SearXNG is already running, returns the
    /// existing pid without launching a second instance.
    ///
    /// - Parameters:
    ///   - pythonExecutablePath: absolute path to the bundled interpreter
    ///     (…/searxng-runtime/python/bin/python3.12), resolved by the app from `Bundle.main`.
    ///   - settingsPath: absolute path to the generated `settings.yml` under ~/searxng-local.
    ///   - bindAddress: interface to bind (127.0.0.1 for the private local instance).
    ///   - port: TCP port to serve on (8080).
    /// Reply: (pid, errorString). pid > 0 on success; pid <= 0 means launch failed (errorString explains).
    func startSearxng(
        pythonExecutablePath: String,
        settingsPath: String,
        bindAddress: String,
        port: Int32,
        reply: @escaping (Int32, String) -> Void
    )

    /// Terminates the tracked SearXNG process (SIGTERM, then SIGKILL fallback) and clears the pidfile.
    /// Reply: true if no SearXNG process remains afterwards.
    func stopSearxng(reply: @escaping (Bool) -> Void)

    /// Reply: true if the tracked SearXNG process (per pidfile) is currently alive.
    func isSearxngRunning(reply: @escaping (Bool) -> Void)

    // MARK: - Tor native process supervision (helper owns the state dir + torrc; app passes bundle paths)

    /// Launches the bundled Tor; the helper generates the torrc and tracks a pidfile. Idempotent
    /// (returns the existing pid if already running). geoip paths may be "" to omit.
    /// Reply: (pid, error). pid > 0 on success.
    func startTor(
        torBinaryPath: String,
        geoipPath: String,
        geoip6Path: String,
        socksPort: Int32,
        reply: @escaping (Int32, String) -> Void
    )

    /// Terminates the tracked Tor process (SIGTERM, then SIGKILL fallback) and clears its pidfile.
    /// Reply: true if no Tor process remains afterwards.
    func stopTor(reply: @escaping (Bool) -> Void)

    /// Reply: true if the tracked Tor process (per pidfile) is currently alive.
    func isTorRunning(reply: @escaping (Bool) -> Void)

    /// Last Tor bootstrap percentage (0...100) parsed from tor.log. Reply: -1 if unknown/not started.
    func torBootstrapProgress(reply: @escaping (Int32) -> Void)

    /// Live circuit relays as JSON Data (`[{"nickname","country","ip"}]`) via the control port, or nil.
    func torControlCircuit(reply: @escaping (Data?) -> Void)

    /// Requests a new Tor identity (SIGNAL NEWNYM). Reply: true on success.
    func torNewIdentity(reply: @escaping (Bool) -> Void)

    // MARK: - File system (App Sandbox)
    //
    // The sandboxed main app cannot access ~/searxng-local directly.
    // All file I/O on that path routes through these methods.

    /// Returns true if a file or directory exists at path.
    func fileExists(atPath path: String, reply: @escaping (Bool) -> Void)

    /// Reads the file at path. Returns nil if not found or unreadable.
    func readFile(atPath path: String, reply: @escaping (Data?) -> Void)

    /// Atomically writes data to path (creates parent directories as needed). Returns true on success.
    func writeFile(data: Data, toPath path: String, reply: @escaping (Bool) -> Void)

    /// Creates a directory at path (withIntermediateDirectories: true).
    /// Returns true if the directory now exists (created or already existed).
    func createDirectory(atPath path: String, reply: @escaping (Bool) -> Void)

    /// Removes the item at path (file or directory tree).
    /// Returns true on success or if the item did not exist.
    func removeItem(atPath path: String, reply: @escaping (Bool) -> Void)
}

// MARK: - Convenience wrappers (async)

extension SearxlyHelperProtocol {

    func startSearxngAsync(
        pythonExecutablePath: String,
        settingsPath: String,
        bindAddress: String,
        port: Int32
    ) async -> (pid: Int32, error: String) {
        await withCheckedContinuation { continuation in
            startSearxng(
                pythonExecutablePath: pythonExecutablePath,
                settingsPath: settingsPath,
                bindAddress: bindAddress,
                port: port
            ) { pid, err in
                continuation.resume(returning: (pid, err))
            }
        }
    }

    func stopSearxngAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            stopSearxng { continuation.resume(returning: $0) }
        }
    }

    func isSearxngRunningAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            isSearxngRunning { continuation.resume(returning: $0) }
        }
    }

    func startTorAsync(
        torBinaryPath: String,
        geoipPath: String,
        geoip6Path: String,
        socksPort: Int32
    ) async -> (pid: Int32, error: String) {
        await withCheckedContinuation { continuation in
            startTor(
                torBinaryPath: torBinaryPath,
                geoipPath: geoipPath,
                geoip6Path: geoip6Path,
                socksPort: socksPort
            ) { pid, err in
                continuation.resume(returning: (pid, err))
            }
        }
    }

    func stopTorAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            stopTor { continuation.resume(returning: $0) }
        }
    }

    func isTorRunningAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            isTorRunning { continuation.resume(returning: $0) }
        }
    }

    func torBootstrapProgressAsync() async -> Int32 {
        await withCheckedContinuation { continuation in
            torBootstrapProgress { continuation.resume(returning: $0) }
        }
    }

    func torControlCircuitAsync() async -> Data? {
        await withCheckedContinuation { continuation in
            torControlCircuit { continuation.resume(returning: $0) }
        }
    }

    func torNewIdentityAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            torNewIdentity { continuation.resume(returning: $0) }
        }
    }

    func fileExistsAsync(atPath path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            fileExists(atPath: path) { continuation.resume(returning: $0) }
        }
    }

    func readFileAsync(atPath path: String) async -> Data? {
        await withCheckedContinuation { continuation in
            readFile(atPath: path) { continuation.resume(returning: $0) }
        }
    }

    func writeFileAsync(data: Data, toPath path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            writeFile(data: data, toPath: path) { continuation.resume(returning: $0) }
        }
    }

    func createDirectoryAsync(atPath path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            createDirectory(atPath: path) { continuation.resume(returning: $0) }
        }
    }

    func removeItemAsync(atPath path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            removeItem(atPath: path) { continuation.resume(returning: $0) }
        }
    }
}
