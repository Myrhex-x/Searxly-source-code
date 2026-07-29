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
    /// Free-text result PLUS a machine-readable payload (MCP `structuredContent`). The JSON is carried
    /// as `Data` (Sendable); the router embeds it and clients with an `outputSchema` can parse it.
    case okStructured(text: String, structuredJSON: Data)
    case failed(String)                                // human-readable failure (surfaced as an MCP tool error)
    case image(base64: String, mimeType: String)       // an image result (e.g. a screenshot)
}

/// Registry-level result of a `tools/call` (adds lookup/enablement outcomes on top of the tool's own).
enum AgenticToolResult: Sendable {
    case ok(String)
    case okStructured(text: String, structuredJSON: Data)
    case failed(String)
    case image(base64: String, mimeType: String)
    case notFound
    case disabled
}

/// A single MCP tool. `id` is the wire name the model calls; it MUST be stable.
@MainActor
protocol AgenticTool {
    var id: String { get }
    var title: String { get }               // human-readable name (Settings + MCP client UIs)
    var summary: String { get }             // description the model sees
    var inputSchema: [String: Any] { get }  // JSON Schema (object)
    /// True for tools that act on / read the user's live browser tab. Hidden + refused unless the user
    /// has turned on the "Browser control" opt-in (these change or expose the real session).
    var requiresBrowserControl: Bool { get }
    /// True for tools that read or write the user's own data (history, bookmarks). Hidden + refused
    /// unless the user has turned on the "Personal data" opt-in.
    var requiresPersonalData: Bool { get }
    /// True when the tool only observes — surfaced to clients as MCP's `readOnlyHint`.
    var isReadOnly: Bool { get }
    /// Optional JSON Schema for the tool's `structuredContent` (MCP `outputSchema`). nil when the tool
    /// returns only text.
    var outputSchema: [String: Any]? { get }
    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome
}

extension AgenticTool {
    var requiresBrowserControl: Bool { false }
    var requiresPersonalData: Bool { false }
    var isReadOnly: Bool { false }
    var outputSchema: [String: Any]? { nil }
    var title: String { id.split(separator: "_").map(\.capitalized).joined(separator: " ") }
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
            // Personal-data tools — require the "Personal data" opt-in; they touch the user's own data.
            SearchHistoryTool(),
            SearchBookmarksTool(),
            AddBookmarkTool(),
            // Browser-action tools — require the "Browser control" opt-in; they act on the live session.
            PageSnapshotTool(),
            DescribeFormTool(),
            ReadCurrentPageTool(),
            ClickTool(),
            TypeTool(),
            FillFormTool(),
            SelectOptionTool(),
            PressKeyTool(),
            ScrollTool(),
            FindTextTool(),
            NavigateTool(),
            GoBackTool(),
            GoForwardTool(),
            ReloadTool(),
            WaitForTool(),
            ScreenshotTool(),
            // Tab tools — browser-control tier; manage the user's open (non-private) tabs.
            ListTabsTool(),
            ReadTabTool(),
            SwitchTabTool(),
            OpenTabTool(),
            CloseTabTool()
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
        let personalData = AgenticServerManager.shared.personalDataEnabled
        return tools
            .filter { AgenticServerManager.shared.isToolEnabled($0.id) }
            .filter { !$0.requiresBrowserControl || browserControl }
            .filter { !$0.requiresPersonalData || personalData }
            .map { tool -> [String: Any] in
                var def: [String: Any] = [
                    "name": tool.id,
                    "title": tool.title,
                    "description": tool.summary,
                    "inputSchema": tool.inputSchema,
                    "annotations": ["title": tool.title, "readOnlyHint": tool.isReadOnly]
                ]
                if let outputSchema = tool.outputSchema { def["outputSchema"] = outputSchema }
                return def
            }
    }

    /// MCP `tools/call` dispatch. `redactPIIOverride` is passed by the in-process answer engine (local
    /// model → no egress → full fidelity); the MCP server path leaves it nil to honor the user's setting.
    func call(name: String, arguments: [String: Any], redactPIIOverride: Bool? = nil) async -> AgenticToolResult {
        guard let tool = tools.first(where: { $0.id == name }) else { return .notFound }
        guard AgenticServerManager.shared.isToolEnabled(name) else { return .disabled }
        if tool.requiresBrowserControl && !AgenticServerManager.shared.browserControlEnabled { return .disabled }
        if tool.requiresPersonalData && !AgenticServerManager.shared.personalDataEnabled { return .disabled }

        // Bulwark tool-call guard: rate limit, exfiltration-shaped arguments, taint gate.
        if let refusal = AgenticToolGuard.shared.preflight(toolID: name, isReadOnly: tool.isReadOnly, arguments: arguments) {
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: false)
            return .failed(refusal)
        }

        let outcome = await tool.run(arguments)
        switch outcome {
        case .ok(let text):
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: true)
            // PII is redacted (Rampart), and untrusted web content is scanned + wrapped as data,
            // before anything reaches the model.
            return .ok(await AgenticToolGuard.shared.processOutput(text, toolID: name, redactPIIOverride: redactPIIOverride))
        case .okStructured(let text, let json):
            AgenticServerManager.shared.recordActivity(tool: name, summary: Self.argSummary(arguments), ok: true)
            // Text channel gets the full guard (redact + wrap); the structured channel is PII-scrubbed too.
            let processedText = await AgenticToolGuard.shared.processOutput(text, toolID: name, redactPIIOverride: redactPIIOverride)
            let scrubbedJSON = await AgenticToolGuard.shared.redactStructured(json, toolID: name, redactPIIOverride: redactPIIOverride)
            return .okStructured(text: processedText, structuredJSON: scrubbedJSON)
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
    let title = "Privacy status"
    let isReadOnly = true
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
