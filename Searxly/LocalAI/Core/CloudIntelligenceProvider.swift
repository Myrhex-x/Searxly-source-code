//
//  CloudIntelligenceProvider.swift
//  Searxly
//
//  "Searxly AI" — the cloud / server-backed provider.
//
//  Talks to an OpenAI-compatible Chat Completions endpoint (`POST {baseURL}/chat/completions`).
//  This is deliberately OpenAI-compatible so the SAME code works against:
//    - the user's LOCAL Ollama during development (Ollama exposes an OpenAI-compatible API at
//      http://127.0.0.1:11434/v1) — this is the default, so nothing leaves the Mac yet, AND
//    - a future hosted Searxly AI backend (vLLM on RunPod Serverless, or the Searxly AI gateway)
//      by changing ONLY the base URL + supplying an API key. No code change needed to "go cloud".
//
//  SECURITY / PRIVACY:
//  - Default baseURL points at the user's local Ollama, so by default this provider is on-device.
//  - Any non-localhost baseURL means prompts, RAG context and attached files leave the Mac and go to
//    that server. The Settings UI surfaces this clearly; the provider is opt-in (searxlyAIEnabled).
//  - `apiKey` is an optional Bearer token. For the eventual production path the app should NOT hold a
//    static upstream key — it should send a short-lived per-session token from Sign-In-With-Ethereum to
//    the Searxly AI *gateway*, and the gateway holds the real model key. The plain key field here is a
//    convenience for pointing at your own self-hosted endpoint during bring-up.
//

import Foundation
import os

final class CloudIntelligenceProvider: IntelligenceProvider {

    var capabilities: ProviderCapabilities

    var baseURL: URL      // OpenAI-compatible base, e.g. http://127.0.0.1:11434/v1  (or https://api.searxly.ai/v1)
    var modelName: String // e.g. "searxly-ai" locally, or "Qwen/Qwen2.5-7B-Instruct" on the server
    var apiKey: String    // optional Bearer token (empty for a local Ollama endpoint)
    var maxOutputTokens: Int // hard cap on generated tokens per request (cost + runaway guard; the server bills per output token)

    init(modelName: String = "searxly-ai",
         baseURL: URL = URL(string: "http://127.0.0.1:11434/v1")!,
         apiKey: String = "",
         maxOutputTokens: Int = 2048) {
        self.modelName = modelName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = ProviderCapabilities(
            supportsStreaming: true,
            maxContextTokensApprox: 16384,
            name: "Searxly AI (\(modelName))",
            supportsNativeTools: false   // server models use plain text generation; native tools are the Apple-only path
        )
    }

    // MARK: - PII redaction (Rampart)
    //
    // When the endpoint is remote (non-loopback) and the user hasn't turned it off, user-typed
    // text is scrubbed of PII before it leaves the Mac and the reply is un-scrubbed on-device.
    // Local / Ollama endpoints (loopback) are never touched — nothing leaves the device there.

    /// True when `url` points off-device (anything but loopback) — the line the security
    /// note above draws, and the gate for whether redaction applies. A missing host is
    /// treated as not-remote (such a URL can't reach a real cloud endpoint anyway).
    static func isRemoteEgress(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private var isRemoteEgress: Bool { Self.isRemoteEgress(baseURL) }

    /// A fresh per-turn redaction guard, or nil when redaction is off or the endpoint is local.
    /// Logs the decision at `.notice` (persisted) so a redaction can be verified after the fact —
    /// counts and host only, never the scrubbed values.
    private func activeRedactionGuard() -> RampartGuard? {
        guard isRemoteEgress else {
            Log.privacy.notice("Rampart: \(self.baseURL.host ?? "endpoint", privacy: .public) is local — no redaction needed")
            return nil
        }
        guard RampartRedactor.shared.isEnabled else {
            Log.privacy.notice("Rampart: redaction is OFF in Settings — cloud send NOT scrubbed")
            return nil
        }
        return RampartRedactor.shared.newSession()
    }

    /// Scrubs the outbound system prompt with the SAME guard session as the user message, so the
    /// placeholder map stays consistent for `reveal`. The system prompt is NOT just static rules — it
    /// carries user data (custom instructions, attached-file excerpts, RAG context), so it must be
    /// redacted before egress too, not only the user message. Unchanged when there's no active guard.
    private func scrubbedInstructions(_ instructions: String?, using guardSession: RampartGuard?) async -> String? {
        guard let guardSession, let instructions, !instructions.isEmpty else { return instructions }
        let scrubbed = await guardSession.protect(instructions)
        if scrubbed.count > 0 {
            Log.privacy.notice("Rampart: scrubbed \(scrubbed.count, privacy: .public) PII span(s) from the system prompt before cloud send [\(scrubbed.summary, privacy: .public)]")
        }
        return scrubbed.text
    }

    // MARK: - Request building

    private func makeRequest(stream: Bool, prompt: String, instructions: String?) throws -> URLRequest {
        var messages: [[String: String]] = []
        if let instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(["role": "user", "content": prompt])

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = stream ? 300 : 180

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": stream,
            "temperature": 0.6,
            // Cap output length. Without this a single runaway/adversarial prompt can generate
            // thousands of billable tokens against the shared key. Tune via `maxOutputTokens`.
            "max_tokens": maxOutputTokens
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        attachGatewayIdentity(to: &request)
        return request
    }

    /// Attaches the wallet-identity headers the Searxly AI gateway uses to resolve tier + enforce limits.
    /// Only added for the gateway host — never for a user's own / local OpenAI-compatible endpoint.
    private func attachGatewayIdentity(to request: inout URLRequest) {
        guard baseURL.absoluteString.hasPrefix(SearxlyGateway.host) else { return }
        for (key, value) in SearxlyAIIdentity.headers() {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Error sanitization
    //
    // User-facing copy must never name the provider, model, or endpoint URL (brand + privacy contract,
    // see AIRules.backendHonestyCloud). The raw upstream detail is preserved under `detailKey` so it still
    // shows up in the manager's "\(error)" diagnostic logs, but NOT in `localizedDescription` — which is
    // what the chat surfaces to the user.

    private static let detailKey = "SearxlyAIDetail"

    /// Maps an HTTP status to neutral, brand-safe user copy.
    private static func userMessage(forStatus status: Int) -> String {
        switch status {
        case 429:        return "Searxly AI is busy right now. Please wait a moment and try again."
        case 401, 403:   return "Searxly AI isn’t available on this build yet."
        case 500...599:  return "Searxly AI is temporarily unavailable. Please try again in a moment."
        default:         return "Searxly AI couldn’t complete that request. Please try again."
        }
    }

    /// Builds an NSError whose `localizedDescription` is safe to show, while stashing the raw detail
    /// (which may include the URL, upstream error text, or model name) for developer logs only.
    private func sanitizedError(code: Int, userMessage: String, detail: String?) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: userMessage]
        if let detail, !detail.isEmpty { info[Self.detailKey] = detail }
        return NSError(domain: "SearxlyAI", code: code, userInfo: info)
    }

    // MARK: - One-shot generation

    func generate(prompt: String, instructions: String?) async throws -> String {
        let guardSession = activeRedactionGuard()
        let outbound: String
        if let guardSession {
            let scrubbed = await guardSession.protect(prompt)
            Log.privacy.notice("Rampart: scrubbed \(scrubbed.count, privacy: .public) PII span(s) before cloud send [\(scrubbed.summary, privacy: .public)]")
            outbound = scrubbed.text
        } else {
            outbound = prompt
        }
        let outboundInstructions = await scrubbedInstructions(instructions, using: guardSession)
        let request = try makeRequest(stream: false, prompt: outbound, instructions: outboundInstructions)
        let (data, response) = try await CertificatePinning.session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let serverMsg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw sanitizedError(code: 2,
                                 userMessage: Self.userMessage(forStatus: status),
                                 detail: "HTTP \(status) at \(baseURL): \(serverMsg)")
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        if let err = decoded.error?.message, !err.isEmpty {
            throw sanitizedError(code: 3,
                                 userMessage: "Searxly AI couldn’t complete that request. Please try again.",
                                 detail: err)
        }
        let content = decoded.choices?.first?.message?.content ?? "(no response from Searxly AI)"
        return guardSession?.reveal(content) ?? content
    }

    // MARK: - Streaming generation (Server-Sent Events)

    func generateStream(prompt: String, instructions: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let guardSession = self.activeRedactionGuard()
                    let outbound: String
                    if let guardSession {
                        let scrubbed = await guardSession.protect(prompt)
                        Log.privacy.notice("Rampart: scrubbed \(scrubbed.count, privacy: .public) PII span(s) before cloud send (stream) [\(scrubbed.summary, privacy: .public)]")
                        outbound = scrubbed.text
                    } else {
                        outbound = prompt
                    }
                    let outboundInstructions = await self.scrubbedInstructions(instructions, using: guardSession)
                    let reveal = guardSession?.makeRevealTransform()
                    let request = try makeRequest(stream: true, prompt: outbound, instructions: outboundInstructions)
                    let (bytes, response) = try await CertificatePinning.session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.finish(throwing: self.sanitizedError(
                            code: 2,
                            userMessage: Self.userMessage(forStatus: status),
                            detail: "HTTP \(status) at \(self.baseURL) (stream)"))
                        return
                    }

                    // OpenAI-compatible streaming is SSE: each event is a line like `data: {json}` and the
                    // stream terminates with `data: [DONE]`.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if payload.isEmpty { continue }
                        guard let data = payload.data(using: .utf8) else { continue }

                        if let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) {
                            if let content = chunk.choices?.first?.delta?.content, !content.isEmpty {
                                if let reveal {
                                    let shown = reveal.push(content)   // restores placeholders, buffering partial tokens
                                    if !shown.isEmpty { continuation.yield(shown) }
                                } else {
                                    continuation.yield(content)
                                }
                            }
                            if chunk.choices?.first?.finishReason != nil { break }
                        } else if let errChunk = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data),
                                  let err = errChunk.error?.message, !err.isEmpty {
                            continuation.finish(throwing: self.sanitizedError(
                                code: 4,
                                userMessage: "Searxly AI couldn’t complete that request. Please try again.",
                                detail: err))
                            return
                        }
                    }

                    if let reveal {
                        let tail = reveal.finish()   // flush any held partial-placeholder tail
                        if !tail.isEmpty { continuation.yield(tail) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func unload() async {
        // Stateless HTTP — nothing to release.
    }

    // MARK: - Agentic tool calling (OpenAI function calling)
    //
    // Runs a multi-round loop: the model may emit `tool_calls`; we execute each via the bound
    // CloudTool executors, feed the results back, and repeat until the model produces a final answer
    // (or we hit `maxRounds`, after which we force a plain answer). The whole turn is non-streaming —
    // it mirrors the existing on-device tools path, and keeps the implementation robust across
    // OpenAI-compatible servers that don't reliably stream tool-call deltas.
    //
    // Returns the final text plus the de-duplicated sources gathered across the turn (for citations).

    func generateWithTools(
        systemPrompt: String?,
        userPrompt: String,
        tools: [CloudTool],
        maxRounds: Int = 4
    ) async throws -> CloudToolResult {
        guard !tools.isEmpty else {
            let text = try await generate(prompt: userPrompt, instructions: systemPrompt)
            return CloudToolResult(text: text, sources: [], toolsUsed: [])
        }

        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let toolSpecs: [[String: Any]] = tools.map { t in
            ["type": "function",
             "function": ["name": t.name, "description": t.description, "parameters": t.parameters]]
        }

        let guardSession = activeRedactionGuard()
        let outboundUserPrompt: String
        if let guardSession {
            let scrubbed = await guardSession.protect(userPrompt)
            Log.privacy.notice("Rampart: scrubbed \(scrubbed.count, privacy: .public) PII span(s) before cloud send (tools) [\(scrubbed.summary, privacy: .public)]")
            outboundUserPrompt = scrubbed.text
        } else {
            outboundUserPrompt = userPrompt
        }

        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            // Scrub the system prompt too — it carries user custom instructions, attached-file
            // excerpts and RAG context, all of which must be redacted before egress.
            let outboundSystem = await scrubbedInstructions(systemPrompt, using: guardSession) ?? systemPrompt
            messages.append(["role": "system", "content": outboundSystem])
        }
        messages.append(["role": "user", "content": outboundUserPrompt])

        var collectedSources: [Citation] = []
        var toolsUsed: [String] = []

        for round in 0..<maxRounds {
            // On the final allowed round, force a plain answer so we never loop forever.
            let forceAnswer = (round == maxRounds - 1)
            let request = try makeToolRequest(messages: messages,
                                              toolSpecs: toolSpecs,
                                              toolChoice: forceAnswer ? "none" : "auto")

            let (data, response) = try await CertificatePinning.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let serverMsg = String(data: data, encoding: .utf8) ?? "unknown error"
                throw sanitizedError(code: 2,
                                     userMessage: Self.userMessage(forStatus: status),
                                     detail: "HTTP \(status) at \(baseURL) (tools): \(serverMsg)")
            }

            let decoded = try JSONDecoder().decode(OpenAIToolResponse.self, from: data)
            if let err = decoded.error?.message, !err.isEmpty {
                throw sanitizedError(code: 3,
                                     userMessage: "Searxly AI couldn’t complete that request. Please try again.",
                                     detail: err)
            }

            let message = decoded.choices?.first?.message
            let calls = message?.tool_calls ?? []

            // No tool calls → this is the final answer.
            if calls.isEmpty || forceAnswer {
                let text = message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let revealed = guardSession?.reveal(text) ?? text
                return CloudToolResult(text: revealed.isEmpty ? "(no response from Searxly AI)" : revealed,
                                       sources: collectedSources,
                                       toolsUsed: toolsUsed)
            }

            // Echo the assistant message (with its tool_calls) back into the running transcript.
            var assistantMsg: [String: Any] = ["role": "assistant", "content": message?.content ?? ""]
            assistantMsg["tool_calls"] = calls.map { tc in
                ["id": tc.id, "type": "function",
                 "function": ["name": tc.function.name, "arguments": tc.function.arguments]]
            }
            messages.append(assistantMsg)

            // Execute each requested tool and append its result as a `tool` message.
            for tc in calls {
                toolsUsed.append(tc.function.name)
                // The model only ever saw placeholders, so its tool arguments carry them too.
                // Reveal them before running a LOCAL tool (the user's own SearXNG) so it searches
                // real terms — that call doesn't egress, so no PII leaves the device here.
                let revealedArgs = guardSession?.reveal(tc.function.arguments) ?? tc.function.arguments
                let args = Self.decodeArguments(revealedArgs)
                let resultText: String
                if let tool = toolsByName[tc.function.name] {
                    let output = await tool.execute(args)
                    collectedSources.append(contentsOf: output.sources)
                    resultText = output.modelText
                } else {
                    resultText = "Error: unknown tool \"\(tc.function.name)\"."
                }
                // Re-scrub the tool result before it goes back up to the cloud model.
                let safeResult = guardSession != nil ? await guardSession!.protect(resultText).text : resultText
                messages.append(["role": "tool", "tool_call_id": tc.id, "content": safeResult])
            }
        }

        // Should be unreachable (forceAnswer returns on the last round), but stay safe.
        let text = try await generate(prompt: userPrompt, instructions: systemPrompt)
        return CloudToolResult(text: text, sources: collectedSources, toolsUsed: toolsUsed)
    }

    private func makeToolRequest(messages: [[String: Any]],
                                 toolSpecs: [[String: Any]],
                                 toolChoice: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": false,
            "temperature": 0.4,            // a little tighter for grounded, tool-driven answers
            "max_tokens": maxOutputTokens
        ]
        // Only advertise tools when there are any. If the user has switched every tool off (per-tool
        // toggles) this degrades cleanly to a normal completion instead of sending an empty `tools: []`,
        // which some OpenAI-compatible backends reject. "none" forces a final answer on the last round.
        if !toolSpecs.isEmpty {
            body["tools"] = toolSpecs
            body["tool_choice"] = toolChoice
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        attachGatewayIdentity(to: &request)
        return request
    }

    /// OpenAI passes function arguments as a JSON *string*; decode it to a dictionary (best effort).
    private static func decodeArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

// MARK: - OpenAI-compatible response shapes

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }
    struct APIError: Decodable { let message: String? }
    let choices: [Choice]?
    let error: APIError?
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]?
}

// MARK: - OpenAI tool-calling response shapes

private struct OpenAIToolResponse: Decodable {
    struct Choice: Decodable {
        let message: ToolMessage?
        let finish_reason: String?
    }
    struct ToolMessage: Decodable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCall]?
    }
    struct ToolCall: Decodable {
        let id: String
        let type: String?
        let function: FunctionCall
    }
    struct FunctionCall: Decodable {
        let name: String
        let arguments: String   // a JSON-encoded string of the arguments object
    }
    struct APIError: Decodable { let message: String? }
    let choices: [Choice]?
    let error: APIError?
}
