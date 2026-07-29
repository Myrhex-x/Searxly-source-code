//
//  MCPProtocol.swift
//  Searxly
//
//  Minimal, hand-rolled Model Context Protocol (MCP) over JSON-RPC 2.0. This is the wire layer
//  for Searxly Agentic Tools: a user's OWN local AI (Ollama / LM Studio / any MCP client) connects
//  to a loopback endpoint and calls Searxly's private-web tools. Nothing here talks to any cloud.
//
//  We implement the small subset MCP needs for request/response tools: `initialize`,
//  `notifications/initialized`, `tools/list`, `tools/call`, `ping`. Transport is MCP "Streamable
//  HTTP" (see MCPServer). Params/arguments are arbitrary JSON, so we parse with JSONSerialization
//  rather than fighting Codable over heterogeneous shapes.
//

import Foundation

// MARK: - Transport value types (Sendable — they cross the transport→MainActor boundary)

/// A parsed inbound HTTP request. Header keys are lowercased for case-insensitive lookup.
struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Value of a query parameter on the request path, percent-decoded (nil if absent).
    func queryValue(_ name: String) -> String? {
        guard let qIndex = path.firstIndex(of: "?") else { return nil }
        for pair in path[path.index(after: qIndex)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == name else { continue }
            let raw = String(parts[1])
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }
}

/// An HTTP response to write back over the connection.
struct MCPHTTPResponse: Sendable {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    static func json(_ data: Data, status: Int = 200) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, reason: reasonPhrase(status),
                        headers: ["Content-Type": "application/json"], body: data)
    }

    static func plain(_ text: String, status: Int) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, reason: reasonPhrase(status),
                        headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: Data(text.utf8))
    }

    /// 202 with no body — the correct reply to a JSON-RPC notification (no response expected).
    static var accepted: MCPHTTPResponse {
        MCPHTTPResponse(status: 202, reason: "Accepted", headers: [:], body: Data())
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

// MARK: - JSON-RPC helpers

enum JSONRPCError {
    static let parse = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// Builds JSON-RPC success/error envelopes as `Data`. `id` is preserved verbatim (number/string/null).
enum JSONRPC {
    static func success(id: Any?, result: [String: Any]) -> Data {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func failure(id: Any?, code: Int, message: String) -> Data {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(),
                   "error": ["code": code, "message": message]])
    }

    static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"serialization failed"}}"#.utf8)
    }
}

// MARK: - Router

/// Dispatches a decoded JSON-RPC request to the tool registry. MainActor because tool handlers read
/// live app state (privacy posture, the user's SearXNG instances, etc.).
@MainActor
enum MCPRouter {
    static let serverName = "searxly-agentic-tools"
    /// Protocol versions we understand. We echo the client's requested version when we support it,
    /// otherwise we answer with our newest.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let latestProtocolVersion = "2025-06-18"

    /// Handle one POST /mcp body. Returns the HTTP response (JSON-RPC result, error, or 202 for a notification).
    static func handlePOST(body: Data) async -> MCPHTTPResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else {
            return .json(JSONRPC.failure(id: nil, code: JSONRPCError.parse, message: "Parse error"), status: 400)
        }
        // Batch requests are rare for tool clients; support a single request object for v1.
        guard let dict = obj as? [String: Any], let method = dict["method"] as? String else {
            return .json(JSONRPC.failure(id: nil, code: JSONRPCError.invalidRequest, message: "Invalid Request"), status: 400)
        }
        let id = dict["id"]                       // absent → notification
        let params = dict["params"] as? [String: Any] ?? [:]
        let isNotification = (id == nil)

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = (requested.map { supportedProtocolVersions.contains($0) } == true) ? requested! : latestProtocolVersion
            let result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": serverName, "title": "Searxly Agentic Tools", "version": SearxlyVersion.short],
                "instructions": "Searxly Agentic Tools — private web access for your local AI. Tools search and read the web through the user's own SearXNG instance; nothing is sent to any AI provider."
            ]
            return .json(JSONRPC.success(id: id, result: result))

        case "notifications/initialized", "notifications/cancelled":
            return .accepted   // notifications get no JSON-RPC response

        case "ping":
            return .json(JSONRPC.success(id: id, result: [:]))

        case "tools/list":
            return .json(JSONRPC.success(id: id, result: ["tools": AgenticToolRegistry.shared.toolDefinitions()]))

        case "tools/call":
            guard let name = params["name"] as? String else {
                return .json(JSONRPC.failure(id: id, code: JSONRPCError.invalidParams, message: "Missing tool name"))
            }
            let arguments = Self.arguments(from: params["arguments"])
            let result = await AgenticToolRegistry.shared.call(name: name, arguments: arguments)
            switch result {
            case .notFound:
                return .json(JSONRPC.failure(id: id, code: JSONRPCError.methodNotFound, message: "Unknown tool: \(name)"))
            case .disabled:
                // Surface as a tool-level error (per MCP: tool failures live in the result, not JSON-RPC error).
                return .json(JSONRPC.success(id: id, result: toolContent("This tool is turned off in Searxly → Settings → Agentic Tools.", isError: true)))
            case .ok(let text):
                return .json(JSONRPC.success(id: id, result: toolContent(text, isError: false)))
            case .okStructured(let text, let structuredJSON):
                var res = toolContent(text, isError: false)
                // `structuredContent` must be a JSON object (tools build one, e.g. {"query":…, "results":[…]}).
                if let obj = try? JSONSerialization.jsonObject(with: structuredJSON) as? [String: Any] {
                    res["structuredContent"] = obj
                }
                return .json(JSONRPC.success(id: id, result: res))
            case .failed(let message):
                return .json(JSONRPC.success(id: id, result: toolContent(message, isError: true)))
            case .image(let base64, let mimeType):
                return .json(JSONRPC.success(id: id, result: ["content": [["type": "image", "data": base64, "mimeType": mimeType]], "isError": false]))
            }

        default:
            if isNotification { return .accepted }
            return .json(JSONRPC.failure(id: id, code: JSONRPCError.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private static func toolContent(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    /// Tool arguments are normally a JSON object, but some small local models emit them as a JSON
    /// *string*. Accept both so a stringified payload still runs.
    private static func arguments(from raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        if let str = raw as? String,
           let data = str.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return dict
        }
        return [:]
    }
}

/// App version string for serverInfo (best-effort from the bundle).
enum SearxlyVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
}
