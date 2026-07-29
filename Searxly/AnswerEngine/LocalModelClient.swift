//
//  LocalModelClient.swift
//  Searxly — Answer Engine
//
//  A tiny OpenAI-compatible client for a LOCAL model server (Ollama, LM Studio, or anything that speaks
//  /v1/chat/completions). It powers Searxly's built-in answer engine: the model is the brain, Searxly's
//  own tools are the hands, and nothing leaves this Mac — the endpoint is loopback-only.
//
//  Deliberately schema-light: requests/responses are plain [String: Any] via JSONSerialization, because
//  tool input schemas are already [String: Any] and models vary in how strictly they follow the spec.
//

import Foundation

enum LocalModelProvider: String, CaseIterable, Identifiable, Codable {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    var id: String { rawValue }
    /// Loopback base URL (OpenAI-compatible `/v1`) for each provider's default install.
    var defaultBaseURL: String {
        switch self {
        case .ollama:   return "http://127.0.0.1:11434/v1"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        }
    }
    var setupHint: String {
        switch self {
        case .ollama:   return "Install Ollama and run a tool-capable model, e.g. `ollama run llama3.1`."
        case .lmStudio: return "In LM Studio, load a model and start the local server (Developer tab)."
        }
    }
}

/// One tool call the model asked for. Stores only the raw JSON-string arguments (Sendable); `arguments`
/// is parsed on demand, so the struct crosses actor boundaries cleanly.
struct ModelToolCall: Sendable {
    let id: String
    let name: String
    let rawArguments: String   // echoed verbatim back to the model in the assistant turn

    var arguments: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(rawArguments.utf8))) as? [String: Any]) ?? [:]
    }
}

/// One assistant turn: free-text content and/or a set of tool calls.
struct ModelCompletion: Sendable {
    let content: String?
    let toolCalls: [ModelToolCall]
}

enum LocalModelError: LocalizedError {
    case unreachable
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable:      return "Couldn't reach the local model. Make sure it's running."
        case .http(let c, _):   return "The local model returned an error (HTTP \(c))."
        case .badResponse:      return "The local model sent a response Searxly couldn't read."
        }
    }
}

struct LocalModelClient {
    let baseURL: String
    let model: String

    private func endpoint(_ path: String) -> URL? {
        URL(string: baseURL.hasSuffix("/") ? baseURL + path : baseURL + "/" + path)
    }

    /// GET /models — returns the served model ids (empty if the server has none loaded).
    func fetchModels() async -> [String] {
        guard let url = endpoint("models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    /// Whether the server answers at all (a loaded model isn't required).
    func reachable() async -> Bool {
        guard let url = endpoint("models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// POST /chat/completions (non-streaming) with optional tool specs. Returns the assistant turn.
    func complete(messages: [[String: Any]], tools: [[String: Any]], timeout: TimeInterval = 120) async throws -> ModelCompletion {
        guard let url = endpoint("chat/completions") else { throw LocalModelError.unreachable }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LocalModelError.unreachable
        }
        guard let http = resp as? HTTPURLResponse else { throw LocalModelError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalModelError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LocalModelError.badResponse
        }
        return Self.parseMessage(message)
    }

    /// Parse an assistant `message` object into a completion. Handles the two ways local models emit tool
    /// arguments — a JSON *string* (the spec) or a JSON *object* (some models). Static + internal so it's
    /// unit-testable without a live server.
    static func parseMessage(_ message: [String: Any]) -> ModelCompletion {
        let content = message["content"] as? String
        var calls: [ModelToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                let id = (tc["id"] as? String) ?? UUID().uuidString
                let raw: String
                if let s = fn["arguments"] as? String {
                    raw = s
                } else if let o = fn["arguments"] as? [String: Any] {
                    raw = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                } else {
                    raw = "{}"
                }
                calls.append(ModelToolCall(id: id, name: name, rawArguments: raw))
            }
        }
        return ModelCompletion(content: content, toolCalls: calls)
    }
}
