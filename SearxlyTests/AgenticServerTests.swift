//
//  AgenticServerTests.swift
//  SearxlyTests
//
//  End-to-end tests for Searxly Agentic Tools: they start the real MCPServer on a loopback port and
//  drive it over HTTP exactly as a user's local-AI MCP client would — proving the JSON-RPC handshake,
//  tool discovery, a live tool call, and the security gate (token + anti-rebinding) all work.
//

import XCTest
import Foundation
@testable import Searxly

@MainActor
final class AgenticServerTests: XCTestCase {

    private let port: UInt16 = 8791
    private var server: MCPServer!

    override func setUp() async throws {
        server = MCPServer()
        try server.start(port: port)
        try await waitUntilReady()
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
    }

    private var endpoint: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    /// POST a JSON-RPC body and return (HTTP status, parsed JSON object if any).
    @discardableResult
    private func post(_ json: String, auth: Bool = true, origin: String? = nil) async throws -> (status: Int, body: [String: Any]?) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth { req.setValue("Bearer \(AgenticServerSecurity.token())", forHTTPHeaderField: "Authorization") }
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        req.httpBody = Data(json.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, body)
    }

    /// Poll `ping` until the listener is accepting (bind is async).
    private func waitUntilReady() async throws {
        for _ in 0..<40 {
            if let result = try? await post(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#), result.status == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("MCP server did not become ready on port \(port)")
    }

    // MARK: - Protocol

    func testInitializeHandshake() async throws {
        let (status, body) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        XCTAssertEqual(status, 200)
        let result = body?["result"] as? [String: Any]
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "searxly-agentic-tools")
        XCTAssertNotNil(result?["capabilities"])
    }

    func testToolsListAdvertisesCoreTools() async throws {
        let (status, body) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(status, 200)
        let tools = (body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["web_search", "read_page", "knowledge_lookup", "open_website", "privacy_status"]), "advertised tools: \(names)")
        for tool in tools {
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "tool \(tool["name"] ?? "?") is missing an object input schema")
            XCTAssertNotNil(tool["description"] as? String)
        }
    }

    func testCallPrivacyStatusReturnsText() async throws {
        let (status, body) = try await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"privacy_status","arguments":{}}}"#)
        XCTAssertEqual(status, 200)
        let result = body?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("Privacy mode") ?? false, "unexpected content: \(text ?? "nil")")
    }

    func testUnknownToolReturnsMethodError() async throws {
        let (status, body) = try await post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(body?["error"], "unknown tool should be a JSON-RPC method error")
    }

    // MARK: - Security gate

    func testRejectsMissingToken() async throws {
        let (status, _) = try await post(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#, auth: false)
        XCTAssertEqual(status, 401)
    }

    func testRejectsBrowserOrigin() async throws {
        // A web page (the DNS-rebinding vector) always sends Origin; a real MCP client never does.
        let (status, _) = try await post(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#, origin: "https://evil.example")
        XCTAssertEqual(status, 403)
    }

    // MARK: - Browser control gate

    func testBrowserControlToolsGatedByToggle() async throws {
        let manager = AgenticServerManager.shared
        let original = manager.browserControlEnabled
        defer { manager.browserControlEnabled = original }

        func listedNames() async throws -> Set<String> {
            let (_, body) = try await post(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)
            let tools = (body?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            return Set(tools.compactMap { $0["name"] as? String })
        }

        manager.browserControlEnabled = false
        let off = try await listedNames()
        XCTAssertFalse(off.contains("click"), "browser-control tools must be hidden when the toggle is off")
        XCTAssertTrue(off.contains("web_search"), "read-only tools remain available when browser control is off")

        manager.browserControlEnabled = true
        let on = try await listedNames()
        XCTAssertTrue(on.isSuperset(of: ["page_snapshot", "click", "type", "navigate", "screenshot"]),
                      "browser-control tools appear when the toggle is on: \(on)")
    }
}
