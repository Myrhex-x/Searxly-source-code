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
    static let defaultPort: UInt16 = 8765

    private(set) var status: AgenticServerStatus = .stopped

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
        }
    }

    /// Live browser context for tools that need the user's instances/tabs (injected from ContentView).
    weak var browserState: BrowserState?

    private var server: MCPServer?
    private var disabledToolIDs: Set<String>

    /// Most-recent-first, capped activity log for the Settings transparency view.
    private(set) var recentActivity: [ActivityEntry] = []
    struct ActivityEntry: Identifiable, Equatable {
        let id = UUID()
        let tool: String
        let summary: String
        let ok: Bool
        let date = Date()
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)   // didSet does not fire in init
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = (storedPort > 1024 && storedPort < 65_536) ? UInt16(storedPort) : Self.defaultPort
        disabledToolIDs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledToolsKey) ?? [])
        browserControlEnabled = UserDefaults.standard.bool(forKey: Self.browserControlKey)
    }

    // MARK: - Derived

    var authToken: String { AgenticServerSecurity.token() }
    var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }
    var isRunning: Bool { status == .running }

    // MARK: - Lifecycle

    /// Called once at launch (after browserState is injected). Starts only if the user enabled it.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        server?.stop()   // tear down any existing listener first (port change / restart) so we never orphan a bound socket
        status = .starting
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
    }

    // MARK: - Activity + token

    func recordActivity(tool: String, summary: String, ok: Bool) {
        recentActivity.insert(ActivityEntry(tool: tool, summary: summary, ok: ok), at: 0)
        if recentActivity.count > 50 { recentActivity.removeLast(recentActivity.count - 50) }
    }

    /// Rotate the bearer token (invalidates clients configured with the old one).
    func rotateToken() { _ = AgenticServerSecurity.regenerateToken() }
}
