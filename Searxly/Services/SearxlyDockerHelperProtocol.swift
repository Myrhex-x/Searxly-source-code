//
//  SearxlyDockerHelperProtocol.swift
//  Shared — add to BOTH Searxly and SearxlyDockerHelper targets in Xcode.
//
//  XPC interface between the Searxly main app (sandboxed) and the
//  SearxlyDockerHelper XPC service (unsandboxed). The service supervises the bundled
//  native Python SearXNG process and performs ~/searxng-local file I/O on the app's behalf.
//
//  (The "Docker" in the name is historical — SearXNG is now a bundled native process, no
//  Docker. The XPC service id com.myrhex.SearxlyDockerHelper is kept to avoid churn.)
//

import Foundation

/// XPC interface between Searxly (main) and SearxlyDockerHelper (XPC service, no sandbox).
///
/// Rules for adding methods:
///   - Use only NSXPCConnection-safe scalar types: String, Bool, Data, Int32.
///   - Collections must NOT appear as @objc parameters — pass them as JSON-encoded Data
///     (NSData is always whitelisted by XPC).
///   - Every method must have exactly one reply block as its last parameter.
///   - The reply block is called exactly once, even on error paths.
@objc protocol SearxlyDockerHelperProtocol {

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

extension SearxlyDockerHelperProtocol {

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
