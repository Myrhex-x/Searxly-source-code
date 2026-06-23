//
//  HelperService.swift
//  SearxlyHelper — XPC Service
//
//  Implements SearxlyHelperProtocol. This process runs without App Sandbox, so it can
//  spawn the bundled native SearXNG (python) process and access ~/searxng-local on behalf of
//  the sandboxed main app. (The runtime is bundled inside the app.)
//

import Foundation

final class HelperService: NSObject, SearxlyHelperProtocol {

    /// Strong reference to the launched SearXNG process, used for a clean terminate while this
    /// service instance is alive. The pidfile (not this) is the source of truth for status/stop,
    /// because the XPC service can be recycled while the child python keeps running.
    private var searxngProcess: Process?

    // MARK: - SearXNG native process supervision

    func startSearxng(
        pythonExecutablePath: String,
        settingsPath: String,
        bindAddress: String,
        port: Int32,
        reply: @escaping (Int32, String) -> Void
    ) {
        // Idempotent: if SearXNG is already running, return the existing pid.
        if let existing = runningSearxngPID() {
            reply(existing, "")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: pythonExecutablePath) else {
            reply(-1, "SearXNG interpreter not found or not executable at \(pythonExecutablePath)")
            return
        }
        guard FileManager.default.fileExists(atPath: settingsPath) else {
            reply(-1, "SearXNG settings.yml not found at \(settingsPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        process.arguments = ["-m", "searx.webapp"]

        // SearXNG reads bind_address/port/settings from these env vars (they override settings.yml),
        // so the helper fully controls where the private instance listens.
        var env = ProcessInfo.processInfo.environment
        env["SEARXNG_SETTINGS_PATH"] = settingsPath
        env["SEARXNG_BIND_ADDRESS"] = bindAddress
        env["SEARXNG_PORT"] = String(port)
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        // Redirect output to a truncated log file under ~/searxng-local. Using a file handle (not a
        // Pipe) means the OS never blocks the child on a full pipe buffer — no drain thread needed
        // for a long-running server, and first-boot logs are available for diagnostics.
        let logURL = searxngStateDir().appendingPathComponent("searxng.log")
        try? FileManager.default.createDirectory(at: searxngStateDir(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] proc in
                try? logHandle.close()
                self?.clearPidfileIfMatches(proc.processIdentifier)
            }
        }

        do {
            try process.run()
        } catch {
            reply(-1, "Failed to launch SearXNG: \(error.localizedDescription)")
            return
        }

        let pid = process.processIdentifier
        searxngProcess = process
        writePidfile(pid)
        reply(pid, "")
    }

    func stopSearxng(reply: @escaping (Bool) -> Void) {
        let pid = runningSearxngPID()
        if let pid {
            kill(pid, SIGTERM)
            // Wait up to ~3s for a graceful exit, then force-kill.
            for _ in 0..<30 where isAlive(pid) { usleep(100_000) }
            if isAlive(pid) {
                kill(pid, SIGKILL)
                usleep(200_000)
            }
        }
        searxngProcess = nil
        clearPidfile()
        // Success = nothing is running anymore.
        reply(pid == nil || !isAlive(pid!))
    }

    func isSearxngRunning(reply: @escaping (Bool) -> Void) {
        reply(runningSearxngPID() != nil)
    }

    // MARK: - File system

    func fileExists(atPath path: String, reply: @escaping (Bool) -> Void) {
        reply(FileManager.default.fileExists(atPath: path))
    }

    func readFile(atPath path: String, reply: @escaping (Data?) -> Void) {
        reply(FileManager.default.contents(atPath: path))
    }

    func writeFile(data: Data, toPath path: String, reply: @escaping (Bool) -> Void) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            reply(true)
        } catch {
            reply(false)
        }
    }

    func createDirectory(atPath path: String, reply: @escaping (Bool) -> Void) {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
            reply(true)
        } catch {
            reply(FileManager.default.fileExists(atPath: path))
        }
    }

    func removeItem(atPath path: String, reply: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { reply(true); return }
        do {
            try FileManager.default.removeItem(atPath: path)
            reply(true)
        } catch {
            reply(false)
        }
    }

    // MARK: - SearXNG process tracking (pidfile)

    private func searxngStateDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("searxng-local")
    }

    private func pidfileURL() -> URL {
        searxngStateDir().appendingPathComponent("searxng.pid")
    }

    private func readPidfile() -> Int32? {
        guard let raw = try? String(contentsOf: pidfileURL(), encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    private func writePidfile(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: searxngStateDir(), withIntermediateDirectories: true)
        try? String(pid).write(to: pidfileURL(), atomically: true, encoding: .utf8)
    }

    private func clearPidfile() {
        try? FileManager.default.removeItem(at: pidfileURL())
    }

    /// Removes the pidfile only if it still names `pid` — avoids a late terminationHandler from an
    /// old process wiping the pidfile of a freshly started one.
    private func clearPidfileIfMatches(_ pid: Int32) {
        if readPidfile() == pid { clearPidfile() }
    }

    /// True if a process with this pid exists and can be signalled (POSIX `kill(pid, 0)`).
    private func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// The pid of a live SearXNG process — from the in-memory handle if this instance launched it,
    /// otherwise from the pidfile. nil if nothing is running.
    private func runningSearxngPID() -> Int32? {
        if let proc = searxngProcess, proc.isRunning { return proc.processIdentifier }
        if let pid = readPidfile(), isAlive(pid) { return pid }
        return nil
    }
}
