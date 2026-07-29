//
//  AgenticServerManager.swift
//  Searxly
//
//  First-class in-app control for Searxly Agentic Tools — the local MCP server that lets a user's OWN
//  local AI call Searxly's private-web tools. Mirrors LocalSearxngManager: an @Observable singleton with
//  a status enum + lifecycle. OFF by default; the user opts in from Settings → Agentic Tools. The server
//  binds loopback only and every request is token-gated (see AgenticServerSecurity).
//

import Foundation
import Observation
import Network
import os

enum AgenticServerStatus: Equatable {
    case stopped
    case starting
    case running
    case error(String)
}

@MainActor
@Observable
final class AgenticServerManager {
    static let shared = AgenticServerManager()

    private static let enabledKey = "Searxly.AgenticServer.Enabled"
    private static let portKey = "Searxly.AgenticServer.Port"
    private static let disabledToolsKey = "Searxly.AgenticServer.DisabledTools"
    private static let browserControlKey = "Searxly.AgenticServer.BrowserControl"
    private static let personalDataKey = "Searxly.AgenticServer.PersonalData"
    private static let redactPIIKey = "Searxly.AgenticServer.RedactPII"
    private static let persistLogKey = "Searxly.AgenticServer.PersistLog"
    private static let confirmActionsKey = "Searxly.AgenticServer.ConfirmActions"
    private static let isolateContextKey = "Searxly.AgenticServer.IsolateContext"
    static let defaultPort: UInt16 = 8765

    private(set) var status: AgenticServerStatus = .stopped

    // MARK: - AI presence (for the in-app "your AI is connected/working" pill)

    /// A connected MCP client currently holds an open SSE stream (Claude Code / Desktop keep one open
    /// for the server→client channel). Updated by MCPServer as streams open and close.
    private(set) var hasConnectedClient = false
    /// True briefly after any tool call, so the UI can pulse "AI acting…".
    private(set) var isActing = false
    private var actingClearTask: Task<Void, Never>?

    enum AIPresence { case off, ready, connected, acting }
    /// What the in-app AI-presence pill should show.
    var aiPresence: AIPresence {
        guard isEnabled, isRunning else { return .off }
        if isActing { return .acting }
        return hasConnectedClient ? .connected : .ready
    }

    func setHasConnectedClient(_ connected: Bool) {
        if hasConnectedClient != connected { hasConnectedClient = connected }
    }

    private func noteActivity() {
        isActing = true
        actingClearTask?.cancel()
        actingClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.isActing = false
        }
    }

    /// Master switch, persisted. Off by default (privacy: no listener until the user asks).
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    var port: UInt16 {
        didSet {
            guard oldValue != port else { return }
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            if isEnabled { start() }   // rebind on the new port
        }
    }

    /// Extra opt-in: lets the browser-action tools (snapshot/click/type/navigate) drive the user's REAL
    /// active tab. OFF by default — they change or expose the live browsing session.
    var browserControlEnabled: Bool {
        didSet {
            guard oldValue != browserControlEnabled else { return }
            UserDefaults.standard.set(browserControlEnabled, forKey: Self.browserControlKey)
            notifyToolListChanged()   // the exposed tool set just changed
        }
    }

    /// Extra opt-in: lets the personal-data tools search the user's browsing history and bookmarks
    /// (and save new bookmarks). OFF by default — this is the user's own data, gated separately.
    var personalDataEnabled: Bool {
        didSet {
            guard oldValue != personalDataEnabled else { return }
            UserDefaults.standard.set(personalDataEnabled, forKey: Self.personalDataKey)
            notifyToolListChanged()   // the exposed tool set just changed
        }
    }

    /// PII shield (Rampart): redact personal information from tool results before the AI sees them.
    /// ON by default — matters most when the AI is a cloud model, where raw values would otherwise
    /// egress. Persisted.
    var redactPIIEnabled: Bool {
        didSet {
            guard oldValue != redactPIIEnabled else { return }
            UserDefaults.standard.set(redactPIIEnabled, forKey: Self.redactPIIKey)
        }
    }

    /// Ask before the AI takes an irreversible action — submitting a form (posting data, creating an
    /// account, sending a message). ON by default. The AI can fill fields freely; only the submit pauses
    /// for a one-tap approval in the app. See AgenticApproval.
    var confirmActionsEnabled: Bool {
        didSet {
            guard oldValue != confirmActionsEnabled else { return }
            UserDefaults.standard.set(confirmActionsEnabled, forKey: Self.confirmActionsKey)
        }
    }

    /// Run browser-control actions in a dedicated, logged-out (ephemeral) tab instead of your real active
    /// tab, so the AI can't act as your authenticated self or read your sessions. OFF by default — opt in
    /// when you want the agent fully walled off from your logged-in browsing.
    var agentIsolatedContext: Bool {
        didSet {
            guard oldValue != agentIsolatedContext else { return }
            UserDefaults.standard.set(agentIsolatedContext, forKey: Self.isolateContextKey)
        }
    }

    /// Keep the activity log across launches. OFF by default (privacy: the in-memory log is the safe
    /// default). Never persisted in the amnesic Maximum edition regardless of this flag.
    var persistActivityLog: Bool {
        didSet {
            guard oldValue != persistActivityLog else { return }
            UserDefaults.standard.set(persistActivityLog, forKey: Self.persistLogKey)
            persistActivityLog ? saveActivityLog() : deleteActivityLog()
        }
    }

    /// Live browser context for tools that need the user's instances/tabs (injected from ContentView).
    weak var browserState: BrowserState?

    private var server: MCPServer?
    private var disabledToolIDs: Set<String>

    /// Most-recent-first, capped activity log for the Settings transparency view.
    private(set) var recentActivity: [ActivityEntry] = []
    struct ActivityEntry: Identifiable, Equatable, Codable {
        let id: UUID
        let tool: String
        let summary: String
        let ok: Bool
        let date: Date
        init(tool: String, summary: String, ok: Bool, date: Date = Date()) {
            self.id = UUID(); self.tool = tool; self.summary = summary; self.ok = ok; self.date = date
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)   // didSet does not fire in init
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = (storedPort > 1024 && storedPort < 65_536) ? UInt16(storedPort) : Self.defaultPort
        disabledToolIDs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledToolsKey) ?? [])
        browserControlEnabled = UserDefaults.standard.bool(forKey: Self.browserControlKey)
        personalDataEnabled = UserDefaults.standard.bool(forKey: Self.personalDataKey)
        // PII shield defaults ON (nil = never chosen → true).
        redactPIIEnabled = UserDefaults.standard.object(forKey: Self.redactPIIKey) as? Bool ?? true
        // Confirm-before-acting defaults ON (safety); context isolation defaults OFF (opt-in).
        confirmActionsEnabled = UserDefaults.standard.object(forKey: Self.confirmActionsKey) as? Bool ?? true
        agentIsolatedContext = UserDefaults.standard.bool(forKey: Self.isolateContextKey)
        persistActivityLog = UserDefaults.standard.bool(forKey: Self.persistLogKey)   // default OFF
        if persistActivityLog, !Edition.isMaximum {
            recentActivity = Self.loadActivityLog()
        }
    }

    // MARK: - Derived

    var authToken: String { AgenticServerSecurity.token() }
    var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }
    /// One-string connection link (token embedded) for clients that only take a URL.
    var connectionLink: String { "\(endpointURL)?key=\(authToken)" }
    var isRunning: Bool { status == .running }

    // MARK: - Lifecycle

    /// Called once at launch (after browserState is injected). Starts only if the user enabled it.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        server?.stop()   // tear down any existing listener first (port change / restart) so we never orphan a bound socket
        status = .starting
        selfTest = .none
        let server = MCPServer()
        self.server = server
        do {
            try server.start(port: port)
            // status → .running arrives via handleListenerState(.ready)
        } catch {
            status = .error(error.localizedDescription)
            Log.app.error("Agentic MCP server failed to start on port \(self.port): \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
        selfTest = .none
        hasConnectedClient = false
        isActing = false
        actingClearTask?.cancel()
    }

    func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .running
            Log.app.notice("Agentic MCP server listening on \(self.endpointURL, privacy: .public)")
        case .failed(let error):
            status = .error(String(describing: error))
            Log.app.error("Agentic MCP server listener failed: \(String(describing: error), privacy: .public)")
        case .cancelled:
            if status != .stopped { status = .stopped }
        default:
            break
        }
    }

    // MARK: - Per-tool enablement

    func isToolEnabled(_ id: String) -> Bool { !disabledToolIDs.contains(id) }

    func setTool(_ id: String, enabled: Bool) {
        if enabled { disabledToolIDs.remove(id) } else { disabledToolIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledToolIDs), forKey: Self.disabledToolsKey)
        notifyToolListChanged()   // a tool appeared/disappeared from discovery
    }

    /// Tell connected MCP clients (over SSE) that the exposed tool set changed, so they re-fetch it.
    func notifyToolListChanged() {
        server?.broadcastToolListChanged()
    }

    // MARK: - Activity + token

    func recordActivity(tool: String, summary: String, ok: Bool) {
        recentActivity.insert(ActivityEntry(tool: tool, summary: summary, ok: ok), at: 0)
        if recentActivity.count > 50 { recentActivity.removeLast(recentActivity.count - 50) }
        if persistActivityLog, !Edition.isMaximum { saveActivityLog() }
        noteActivity()
    }

    // MARK: - Activity log export + persistence

    /// A readable, self-contained export of the current activity log (labels + argument summaries
    /// only — never full payloads, matching what `recordActivity` stores).
    func exportActivityText() -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        var lines = ["Searxly Agentic Tools — activity log",
                     "Exported \(df.string(from: Date()))",
                     "\(recentActivity.count) entr\(recentActivity.count == 1 ? "y" : "ies") (most recent first)", ""]
        if recentActivity.isEmpty { lines.append("(no activity recorded)") }
        for e in recentActivity {
            lines.append("\(df.string(from: e.date))  [\(e.ok ? "ok" : "blocked")]  \(e.tool) — \(e.summary)")
        }
        return lines.joined(separator: "\n")
    }

    private static func logFileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("Searxly", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("agentic_activity.json")
    }

    private func saveActivityLog() {
        guard let url = Self.logFileURL(), let data = try? JSONEncoder().encode(recentActivity) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadActivityLog() -> [ActivityEntry] {
        guard let url = logFileURL(), let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([ActivityEntry].self, from: data) else { return [] }
        return entries
    }

    private func deleteActivityLog() {
        if let url = Self.logFileURL() { try? FileManager.default.removeItem(at: url) }
    }

    /// Rotate the bearer token (invalidates clients configured with the old one).
    func rotateToken() { _ = AgenticServerSecurity.regenerateToken() }

    // MARK: - Self-test ("Check connection" in Settings)

    enum SelfTestState: Equatable {
        case none
        case running
        case ok
        case failed(String)
    }

    private(set) var selfTest: SelfTestState = .none

    /// Connects to our own endpoint exactly like an external MCP client would (real TCP + token) and
    /// reports the result — instant, plain-language proof for the user that setup will work.
    func runSelfTest() {
        guard isRunning else {
            selfTest = .failed("Turn on Agentic Tools first.")
            return
        }
        guard let url = URL(string: endpointURL) else {
            selfTest = .failed("Invalid endpoint URL.")
            return
        }
        selfTest = .running

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["result"] != nil else {
                    selfTest = .failed("The server answered, but not as expected.")
                    return
                }
                selfTest = .ok
            } catch {
                selfTest = .failed(error.localizedDescription)
            }
        }
    }
}
