//
//  MCPServer.swift
//  Searxly
//
//  Loopback HTTP transport for the MCP endpoint (MCP "Streamable HTTP"). Binds 127.0.0.1 only, so no
//  other machine can reach it; `AgenticServerSecurity` then gates each request (token + anti-rebinding).
//
//  v1 handles `POST /mcp` (JSON-RPC request → JSON response). `GET /mcp` opens a minimal keep-alive SSE
//  stream so clients that expect the server→client channel don't error; we don't push server-initiated
//  messages yet. Everything runs on the main actor — a local tool server is low-QPS and NWConnection
//  I/O is non-blocking — with the Network.framework callbacks hopping back via `Task { @MainActor }`.
//

import Foundation
import Network
import os

@MainActor
final class MCPServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: MCPConnection] = [:]
    private let queue = DispatchQueue(label: "com.searxly.agentic.mcp", qos: .userInitiated)

    /// Start listening on 127.0.0.1:<port>. Throws if the port can't be bound.
    func start(port: UInt16) throws {
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind the loopback interface only — non-loopback clients can't even connect.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            Task { @MainActor in AgenticServerManager.shared.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in self.accept(connection) }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections { conn.close() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        // Defense-in-depth: even though we bound loopback, refuse any non-loopback peer.
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let handler = MCPConnection(connection: connection, queue: queue) { [weak self] id in
            self?.connections[id] = nil
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let v4): return v4.isLoopback
            case .ipv6(let v6): return v6.isLoopback
            case .name(let name, _): return name == "localhost"
            @unknown default: return false
            }
        }
        return false
    }
}

// MARK: - One connection: read a single HTTP request, respond, close (or hold open for SSE)

@MainActor
final class MCPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onDone: (ObjectIdentifier) -> Void
    private var buffer = Data()
    private var finished = false

    /// Guard rails on a single request so a misbehaving client can't exhaust memory.
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 4 * 1024 * 1024

    init(connection: NWConnection, queue: DispatchQueue, onDone: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onDone = onDone
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { Task { @MainActor in self.close() } }
            if case .cancelled = state { Task { @MainActor in self.finish() } }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty { self.buffer.append(data) }
                if let error {
                    Log.app.error("MCP connection receive error: \(error.localizedDescription, privacy: .public)")
                    self.close(); return
                }
                self.tryHandle(peerClosed: isComplete)
            }
        }
    }

    /// Parse the accumulated bytes; when a full request is present, handle it.
    private func tryHandle(peerClosed: Bool) {
        guard !finished else { return }

        guard let headerEnd = Self.range(of: "\r\n\r\n", in: buffer) else {
            if buffer.count > Self.maxHeaderBytes { respondAndClose(.plain("Headers too large", status: 400)); return }
            if peerClosed { close() } else { receive() }
            return
        }

        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            respondAndClose(.plain("Bad request", status: 400)); return
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { respondAndClose(.plain("Bad request", status: 400)); return }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > Self.maxBodyBytes { respondAndClose(.plain("Body too large", status: 413)); return }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        if available < contentLength {
            if peerClosed { close() } else { receive() }   // wait for the rest of the body
            return
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        let request = MCPHTTPRequest(method: method, path: path, headers: headers, body: body)
        handle(request)
    }

    private func handle(_ request: MCPHTTPRequest) {
        finished = true

        // Only the /mcp endpoint exists.
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            respondAndClose(.plain("Not found", status: 404)); return
        }
        if let rejection = AgenticServerSecurity.rejection(for: request) {
            respondAndClose(rejection); return
        }

        switch request.method {
        case "POST":
            Task { @MainActor in
                let response = await MCPRouter.handlePOST(body: request.body)
                self.respondAndClose(response)
            }
        case "GET":
            // Minimal SSE stream: 200 text/event-stream, one comment, held open (no server push yet).
            sendSSEOpening()
        case "DELETE":
            respondAndClose(.plain("", status: 200))   // client closing its session — nothing to tear down yet
        default:
            respondAndClose(.plain("Method not allowed", status: 405))
        }
    }

    // MARK: - Writing

    private func respondAndClose(_ response: MCPHTTPResponse) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.close() }
        })
    }

    private func sendSSEOpening() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: searxly mcp\n\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        // Intentionally left open; the client closes it when done.
    }

    func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !buffer.isEmpty || true else { return }
        onDone(ObjectIdentifier(self))
    }

    // MARK: - Helpers

    /// First byte range of `needle` inside `data` (needle is ASCII).
    private static func range(of needle: String, in data: Data) -> Range<Int>? {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let bytes = [UInt8](data)
        let upper = bytes.count - pattern.count
        var i = 0
        while i <= upper {
            if bytes[i] == pattern[0], Array(bytes[i..<i+pattern.count]) == pattern {
                return i..<(i + pattern.count)
            }
            i += 1
        }
        return nil
    }
}
