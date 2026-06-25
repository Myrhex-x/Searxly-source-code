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

    /// Same role as `searxngProcess`, for the bundled Tor client. The Tor pidfile is the source of
    /// truth for status/stop across XPC-service recycling.
    private var torProcess: Process?

    /// Tor ControlPort (localhost). Cookie-authenticated; used for live circuit info + new identity.
    /// Deliberately distinct from the SOCKS port (19050) and off Tor's defaults to avoid collisions.
    private static let controlPort: UInt16 = 19051

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

    // MARK: - Tor native process supervision

    func startTor(
        torBinaryPath: String,
        geoipPath: String,
        geoip6Path: String,
        socksPort: Int32,
        reply: @escaping (Int32, String) -> Void
    ) {
        // Idempotent: if Tor is already running, return the existing pid.
        if let existing = runningTorPID() {
            reply(existing, "")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: torBinaryPath) else {
            reply(-1, "Tor binary not found or not executable at \(torBinaryPath)")
            return
        }

        let stateDir = torStateDir()
        let dataDir = stateDir.appendingPathComponent("data")
        let torrcURL = stateDir.appendingPathComponent("torrc")
        let logURL = stateDir.appendingPathComponent("tor.log")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // Generate the torrc. SOCKS5 on localhost is what onion tabs proxy through; ClientOnly means
        // we never act as a relay; notice log → stdout (we capture it to tor.log for the bootstrap
        // parser). GeoIP files are optional (Tor still works without them; they only aid path choice).
        var torrc = """
        SocksPort \(socksHost()):\(socksPort) IsolateDestAddr IsolateDestPort
        ControlPort \(socksHost()):\(Self.controlPort)
        CookieAuthentication 1
        DataDirectory \(dataDir.path)
        ClientOnly 1
        AvoidDiskWrites 1
        Log notice stdout

        """
        if !geoipPath.isEmpty, FileManager.default.fileExists(atPath: geoipPath) {
            torrc += "GeoIPFile \(geoipPath)\n"
        }
        if !geoip6Path.isEmpty, FileManager.default.fileExists(atPath: geoip6Path) {
            torrc += "GeoIPv6File \(geoip6Path)\n"
        }
        do {
            try torrc.write(to: torrcURL, atomically: true, encoding: .utf8)
        } catch {
            reply(-1, "Failed to write torrc: \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: torBinaryPath)
        process.arguments = ["-f", torrcURL.path]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        // Truncate the previous log so the bootstrap parser only ever sees the current run, then
        // capture stdout+stderr into it (single writer — torrc logs to stdout).
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] proc in
                try? logHandle.close()
                self?.clearTorPidfileIfMatches(proc.processIdentifier)
            }
        }

        do {
            try process.run()
        } catch {
            reply(-1, "Failed to launch Tor: \(error.localizedDescription)")
            return
        }

        let pid = process.processIdentifier
        torProcess = process
        writeTorPidfile(pid)
        reply(pid, "")
    }

    func stopTor(reply: @escaping (Bool) -> Void) {
        let pid = runningTorPID()
        if let pid {
            kill(pid, SIGTERM)
            for _ in 0..<30 where isAlive(pid) { usleep(100_000) }
            if isAlive(pid) {
                kill(pid, SIGKILL)
                usleep(200_000)
            }
        }
        torProcess = nil
        clearTorPidfile()
        reply(pid == nil || !isAlive(pid!))
    }

    func isTorRunning(reply: @escaping (Bool) -> Void) {
        reply(runningTorPID() != nil)
    }

    func torBootstrapProgress(reply: @escaping (Int32) -> Void) {
        let logURL = torStateDir().appendingPathComponent("tor.log")
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
            reply(-1)
            return
        }
        // Tor logs lines like: "... [notice] Bootstrapped 100% (done): Done". Take the last %.
        var last: Int32 = -1
        contents.enumerateLines { line, _ in
            guard let range = line.range(of: "Bootstrapped ") else { return }
            let after = line[range.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let pct = Int32(digits) { last = pct }
        }
        reply(last)
    }

    // MARK: - Tor control port (live circuit + new identity)

    private func controlCookiePath() -> String {
        torStateDir().appendingPathComponent("data/control_auth_cookie").path
    }

    /// Returns the relays of Tor's most recently built circuit as JSON
    /// (`[{"nickname":…, "country":…, "ip":…}]`), or nil if the control port is unavailable.
    func torControlCircuit(reply: @escaping (Data?) -> Void) {
        let cookie = controlCookiePath()
        guard let statusResp = TorControl.exchange(
            host: "127.0.0.1", port: Self.controlPort, cookiePath: cookie,
            commands: ["GETINFO circuit-status"]
        )?.first else { reply(nil); return }

        // Pick the path of the most recent BUILT circuit. Lines look like:
        //   <id> BUILT $FP~nick,$FP~nick,$FP~nick BUILD_FLAGS=… PURPOSE=… …
        var path: [(fp: String, nick: String)] = []
        for raw in statusResp.components(separatedBy: "\r\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1] == "BUILT" else { continue }
            let hops = parts[2].split(separator: ",").map { seg -> (String, String) in
                let comps = seg.split(separator: "~", maxSplits: 1)
                let fp = String(comps.first ?? "").replacingOccurrences(of: "$", with: "")
                let nick = comps.count > 1 ? String(comps[1]) : ""
                return (fp, nick)
            }
            if !hops.isEmpty { path = hops }   // keep overwriting → ends on the last BUILT circuit
        }
        guard !path.isEmpty else { reply(nil); return }

        // Resolve each relay's IP (ns/id) then country (ip-to-country), best-effort.
        var relays: [[String: String]] = []
        for hop in path {
            var ip = ""
            var country = ""
            if let ns = TorControl.exchange(
                host: "127.0.0.1", port: Self.controlPort, cookiePath: cookie,
                commands: ["GETINFO ns/id/\(hop.fp)"]
            )?.first {
                // "r <nick> <id> <digest> <date> <time> <IP> <ORPort> <DirPort>"
                for raw in ns.components(separatedBy: "\r\n") where raw.hasPrefix("r ") {
                    let f = raw.split(separator: " ")
                    if f.count >= 7 { ip = String(f[6]) }
                    break
                }
            }
            if !ip.isEmpty, let cc = TorControl.exchange(
                host: "127.0.0.1", port: Self.controlPort, cookiePath: cookie,
                commands: ["GETINFO ip-to-country/\(ip)"]
            )?.first {
                // "250-ip-to-country/<ip>=<cc>"
                if let eq = cc.range(of: "=") {
                    country = cc[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\r\n").first?.uppercased() ?? ""
                }
            }
            relays.append(["nickname": hop.nick, "ip": ip, "country": country])
        }

        reply(try? JSONSerialization.data(withJSONObject: relays))
    }

    /// Requests a fresh identity (SIGNAL NEWNYM) — new circuits for subsequent streams.
    func torNewIdentity(reply: @escaping (Bool) -> Void) {
        let ok = TorControl.exchange(
            host: "127.0.0.1", port: Self.controlPort, cookiePath: controlCookiePath(),
            commands: ["SIGNAL NEWNYM"]
        )?.first?.contains("250") ?? false
        reply(ok)
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

    // MARK: - Tor process tracking (pidfile)

    private func socksHost() -> String { "127.0.0.1" }

    private func torStateDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Searxly/tor")
    }

    private func torPidfileURL() -> URL {
        torStateDir().appendingPathComponent("tor.pid")
    }

    private func readTorPidfile() -> Int32? {
        guard let raw = try? String(contentsOf: torPidfileURL(), encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    private func writeTorPidfile(_ pid: Int32) {
        try? FileManager.default.createDirectory(at: torStateDir(), withIntermediateDirectories: true)
        try? String(pid).write(to: torPidfileURL(), atomically: true, encoding: .utf8)
    }

    private func clearTorPidfile() {
        try? FileManager.default.removeItem(at: torPidfileURL())
    }

    private func clearTorPidfileIfMatches(_ pid: Int32) {
        if readTorPidfile() == pid { clearTorPidfile() }
    }

    /// The pid of a live Tor process — from the in-memory handle if this instance launched it,
    /// otherwise from the pidfile. nil if nothing is running.
    private func runningTorPID() -> Int32? {
        if let proc = torProcess, proc.isRunning { return proc.processIdentifier }
        if let pid = readTorPidfile(), isAlive(pid) { return pid }
        return nil
    }
}

// MARK: - Tor control-protocol client (blocking, localhost)

/// Minimal synchronous client for Tor's ControlPort. Runs only in the unsandboxed helper, which can
/// read the control auth cookie. Best-effort: returns nil on any failure (callers fall back). Uses a
/// plain blocking POSIX socket — exchanges are tiny and localhost-only, with recv/send timeouts.
private enum TorControl {

    static func exchange(host: String, port: UInt16, cookiePath: String, commands: [String]) -> [String]? {
        guard let cookie = FileManager.default.contents(atPath: cookiePath), !cookie.isEmpty else { return nil }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        func sendLine(_ s: String) -> Bool {
            let bytes = Array((s + "\r\n").utf8)
            return bytes.withUnsafeBytes { raw in write(fd, raw.baseAddress, bytes.count) } == bytes.count
        }

        // Read until the final reply line ("<3 digits><space>…") arrives, or timeout.
        func readReply() -> String {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
                guard let s = String(data: out, encoding: .utf8) else { continue }
                let lines = s.components(separatedBy: "\r\n")
                if lines.count >= 2 {
                    let last = lines[lines.count - 2]
                    if last.count >= 4,
                       last.prefix(3).allSatisfy({ $0.isNumber }),
                       last[last.index(last.startIndex, offsetBy: 3)] == " " {
                        break
                    }
                }
            }
            return String(data: out, encoding: .utf8) ?? ""
        }

        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        guard sendLine("AUTHENTICATE \(hex)") else { return nil }
        guard readReply().hasPrefix("250") else { return nil }

        var responses: [String] = []
        for cmd in commands {
            guard sendLine(cmd) else { return nil }
            responses.append(readReply())
        }
        return responses
    }
}
