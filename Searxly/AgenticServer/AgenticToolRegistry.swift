//
//  AgenticToolRegistry.swift
//  Searxly
//
//  The set of tools Searxly exposes to a user's local AI over MCP, plus the dispatcher that runs
//  them. Everything here is MainActor because tool handlers read live app state (privacy posture,
//  the user's SearXNG instances, etc.). Tools are thin wrappers over existing Searxly services —
//  the registry adds MCP metadata, per-tool enablement, and activity logging.
//

import Foundation

/// What a tool returns to the model.
enum AgenticToolOutcome: Sendable {
    case ok(String)                                    // free-text result the model reads
    case failed(String)                                // human-readable failure (surfaced as an MCP tool error)
    case image(base64: String, mimeType: String)       // an image result (e.g. a screenshot)
}

/// Registry-level result of a `tools/call` (adds lookup/enablement outcomes on top of the tool's own).
enum AgenticToolResult: Sendable {
    case ok(String)
    case failed(String)
    case image(base64: String, mimeType: String)
    case notFound
    case disabled
}

/// A single MCP tool. `id` is the wire name the model calls; it MUST be stable.
@MainActor
protocol AgenticTool {
    var id: String { get }
    var summary: String { get }             // description the model sees
    var inputSchema: [String: Any] { get }  // JSON Schema (object)
    /// True for tools that act on / read the user's live browser tab. Hidden + refused unless the user
    /// has turned on the "Browser control" opt-in (these change or expose the real session).
    var requiresBrowserControl: Bool { get }
    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome
}

extension AgenticTool {
    var requiresBrowserControl: Bool { false }
}

@MainActor
final class AgenticToolRegistry {
    static let shared = AgenticToolRegistry()

    /// Live tool list. Phase A ships only `privacy_status`; Phase B appends the private-web tools.
    private(set) var tools: [any AgenticTool]

    private init() {
        tools = [
            WebSearchTool(),        // private web search via the user's own SearXNG
            ReadPageTool(),         // fetch a page's readable text (SSRF-guarded)
            KnowledgeLookupTool(),  // structured fact card for a well-known entity
            OpenWebsiteTool(),      // open a site in a new tab (explicit navigation only)
            PrivacyStatusTool(),    // report Tor/VPN/mode posture
            // Browser-action tools — require the "Browser control" opt-in; they act on the active tab.
            PageSnapshotTool(),
            ClickTool(),
            TypeTool(),
            SelectOptionTool(),
            PressKeyTool(),
            ScrollTool(),
            NavigateTool(),
            GoBackTool(),
            ReloadTool(),
            WaitForTool(),
            ScreenshotTool()
        ]
    }

    /// Register additional tools (called from Phase B wiring once BrowserState is available).
    func register(_ newTools: [any AgenticTool]) {
        for t in newTools where !tools.contains(where: { $0.id == t.id }) {
            tools.append(t)
        }
    }

    /// MCP `tools/list` payload — only tools the user currently has enabled.
    func toolDefinitions() -> [[String: Any]] {
        let browserControl = AgenticServerManager.shared.browserControlEnabled
        return tools
            .filter { AgenticServerManager.shared.isToolEnabled($0.id) }
            .filter { !$0.requiresBrowserControl || browserControl }
            .map { ["name": $0.id, "description": $0.summary, "inputSchema": $0.inputSchema] }
    }

    /// MCP `tools/call` dispatch.
    func call(name: String, arguments: [String: Any]) async -> AgenticToolResult {
        guard let tool = tools.first(where: { $0.id == name }) else { return .notFound }
        guard AgenticServerManager.shared.isToolEnabled(name) else { return .disabled }
        if tool.requiresBrowserControl && !AgenticServerManager.shared.browserControlEnabled { return .disabled }

        let outcome = await tool.run(arguments)
        switch outcome {
        case .ok(let text):
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: true)
            return .ok(text)
        case .failed(let message):
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: false)
            return .failed(message)
        case .image(let base64, let mimeType):
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: true)
            return .image(base64: base64, mimeType: mimeType)
        }
    }

    /// Short, log-safe summary of the arguments for the activity view (never logs full payloads).
    private static func argSummary(_ args: [String: Any]) -> String {
        let parts = args.prefix(3).map { key, value -> String in
            let v = String(describing: value)
            return "\(key)=\(v.count > 40 ? String(v.prefix(40)) + "…" : v)"
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - privacy_status (Phase A proof tool — read-only, uses only shared managers)

@MainActor
struct PrivacyStatusTool: AgenticTool {
    let id = "privacy_status"
    let summary = "Report the user's current privacy posture in Searxly: privacy mode (normal/encrypted/maximum), whether Tor and the VPN are active. Read-only; use to tell the user how private their session is right now."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        let mode: String
        switch PrivacyManager.shared.appPrivacyMode {
        case .normal:    mode = "Normal"
        case .encrypted: mode = "Encrypted (data-at-rest encryption on)"
        case .maximum:   mode = "Maximum Privacy (locked to Tor/VPN + strict fingerprinting)"
        }
        let tor = TorManager.shared.isEnabled
            ? (TorManager.shared.isRunning ? "Tor: on and running" : "Tor: enabled (starting)")
            : "Tor: off"
        let vpn = SystemVPNManager.shared.isConnected ? "VPN: connected" : "VPN: not connected"

        let text = """
        Privacy mode: \(mode)
        \(tor)
        \(vpn)
        """
        return .ok(text)
    }
}
