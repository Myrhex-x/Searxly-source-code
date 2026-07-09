//
//  AgenticServerSecurity.swift
//  Searxly
//
//  Security gate for the local MCP server. This server can drive private search and page reads, so it
//  is defended even though it only ever listens on loopback:
//    1. Bearer token — every request must carry `Authorization: Bearer <token>`. The token is generated
//       once, stored in the Keychain, and shown to the user in Settings to paste into their MCP client.
//    2. Origin rejection — any request carrying an `Origin` header is refused. Legit MCP clients never
//       send one; a browser page (the DNS-rebinding vector) always does.
//    3. Host allow-list — `Host` must be a loopback name. Together with (2) this blocks DNS-rebinding,
//       the main way a malicious web page could reach a localhost server.
//
//  Runs on the main actor alongside the transport (a local tool server is low-QPS, so the occasional
//  Keychain read costs nothing); the token is cached in memory after first load.
//

import Foundation
import Security

enum AgenticServerSecurity {

    /// In-memory cache so we don't hit the Keychain on every request.
    private static var cachedToken: String?

    private static let service = "com.searxly.agentic-tools"
    private static let account = "mcp-bearer-token.v1"

    // MARK: - Token

    /// The current bearer token, creating and persisting one on first use.
    static func token() -> String {
        if let cached = cachedToken { return cached }
        if let existing = loadToken() { cachedToken = existing; return existing }
        let fresh = generateToken()
        saveToken(fresh)
        return fresh
    }

    /// Rotate the token (invalidates any client configured with the old one).
    @discardableResult
    static func regenerateToken() -> String {
        let fresh = generateToken()
        saveToken(fresh)
        return fresh
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Extremely unlikely; fall back to UUIDs so we never ship an empty/predictable token.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request validation

    /// Returns a rejection response if the request must be refused, or nil if it may proceed.
    static func rejection(for request: MCPHTTPRequest) -> MCPHTTPResponse? {
        // (2) No browser-style Origin allowed.
        if request.header("origin") != nil {
            return .plain("Origin not allowed", status: 403)
        }
        // (3) Host must be loopback.
        let host = (request.header("host") ?? "").split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
        guard loopbackHosts.contains(host) else {
            return .plain("Host not allowed", status: 403)
        }
        // (1) Bearer token.
        let provided = bearer(from: request.header("authorization"))
        guard let provided, constantTimeEquals(provided, token()) else {
            return .plain("Unauthorized", status: 401)
        }
        return nil
    }

    private static func bearer(from authorization: String?) -> String? {
        guard let value = authorization else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    /// Length-independent constant-time comparison to avoid leaking the token via timing.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        for i in 0..<max(ab.count, bb.count) {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    // MARK: - Keychain (generic password, device-only)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func saveToken(_ token: String) {
        cachedToken = token
        let data = Data(token.utf8)
        if SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return
        }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }
}
