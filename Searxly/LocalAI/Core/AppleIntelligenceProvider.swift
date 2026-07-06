//
//  AppleIntelligenceProvider.swift
//  Searxly
//
//  NEW FILE (Phase 0 scaffolding).
//  Concrete provider for Apple's on-device FoundationModels (primary path).
//  All real model work lives here so the rest of Searxly stays clean.
//  Phase 0: only the availability probe + no-op stubs (safe, does nothing harmful).
//  Real generation logic lands in Phase 1 (rewrite) / Phase 2 (synthesis) etc.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// FoundationModels (LanguageModelSession, SystemLanguageModel, Tool, @Generable) is a macOS 26+
// framework. The whole provider is gated to macOS 26 so the app can deploy to older macOS (where
// on-device Apple Intelligence simply reports unavailable and the AI UI disables itself). Apple
// Silicon only — there is no Intel path to support.
@available(macOS 26.0, *)
final class AppleIntelligenceProvider: IntelligenceProvider {

    let capabilities = ProviderCapabilities(
        supportsStreaming: true,
        maxContextTokensApprox: 4096,   // Conservative; actual varies by model + iOS/macOS version
        name: "Apple Intelligence (on-device)",
        supportsNativeTools: true   // Native Tool + Generable support on macOS 27+ / FoundationModels
    )

    private var currentSession: LanguageModelSession?   // Reused for multi-turn chat speed (avoids repeated model load)
    private var lastInstructionsHash: Int? = nil   // Only recreate when the *base system contract* actually changes. Per-turn varying context (search/RAG/attached files) belongs in the prompt text, not the instructions used for the LanguageModelSession.

    // Returns only the stable persona + grounding + tool rules contract for LanguageModelSession creation / reuse hashing.
    // Strips the per-turn "Current search context", RAG items, and attached-files blocks that the caller appends.
    // This lets normal follow-ups in a chat reuse the same LanguageModelSession (Apple keeps internal transcript state)
    // instead of recreating on every turn because the full system prompt text changed.
    //
    // The search is tolerant of exact leading whitespace/newlines so that small changes in
    // AIPromptLibrary / prepareSystemPrompt concatenation don't accidentally leave per-turn data
    // in the "base" (which would defeat reuse and/or pollute the persistent instructions with
    // query-specific RAG lists).
    private func baseInstructionsForSession(_ instructions: String?) -> String {
        guard let s = instructions, !s.isEmpty else { return "" }
        var base = s
        // Distinctive marker texts (without relying on exact "\n\n" prefix) for per-turn varying data.
        // Custom instructions ("USER PREFERENCES FOR THIS CHAT ONLY") are intentionally *not* here:
        // they are chat-level and belong in the stable base so they affect the LanguageModelSession
        // for the whole conversation (and cause a recreate only when the user actually edits them).
        let varyingSubstrings = [
            "Current search context (use for citations):",
            "Relevant items from the user's own local browsing history and bookmarks (RAG).",
            "USER-ATTACHED LOCAL FILES (trusted personal context):"
        ]
        // Find the earliest occurrence of any varying marker and truncate before it.
        var cutIndex: String.Index? = nil
        for sub in varyingSubstrings {
            if let r = base.range(of: sub, options: .caseInsensitive) {
                if cutIndex == nil || r.lowerBound < cutIndex! {
                    cutIndex = r.lowerBound
                }
            }
        }
        if let idx = cutIndex {
            base = String(base[..<idx])
        }
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Live Availability (the real check)

    static func probeAvailability() async -> IntelligenceAvailability {
        // Developer override (declared in DeveloperSettings but was never wired until now).
        // Lets you test the entire Local AI chat / synthesis / RAG UI + sheets on machines
        // without Apple Intelligence enrolled or on non-supported hardware.
        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.mockAppleIntelligenceAvailability {
            if DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Probe: MOCKED .available via DeveloperSettings.mockAppleIntelligenceAvailability")
            }
            return .available
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Probe: SystemLanguageModel is .available")
            }
            return .available
        case .unavailable(let reason):
            // The exact case names in SystemLanguageModel.Availability.UnavailableReason can vary slightly by SDK.
            // We map the common ones defensively and fall back gracefully.
            // P6: lowercased contains for extra robustness across SDK descriptions.
            let reasonString = String(describing: reason).lowercased()
            if reasonString.contains("appleintelligencenotenabled") || reasonString.contains("notenabled") {
                return .appleIntelligenceNotEnabled
            } else if reasonString.contains("devicenotsupported") || reasonString.contains("notsupported") {
                return .deviceNotSupported
            } else if reasonString.contains("modelnotready") || reasonString.contains("notready") {
                return .modelNotReady
            } else {
                return .unavailable("Apple Intelligence unavailable: \(reasonString)")
            }
        }
        #else
        return .deviceNotSupported
        #endif
    }

    // MARK: - IntelligenceProvider

    func generate(prompt: String, instructions: String?) async throws -> String {
        #if canImport(FoundationModels)
        // Reuse the LanguageModelSession across turns for much better speed (avoids full model reload on every message).
        // Use only the *stable base contract* (core identity + grounding + tool rules) for the hash and for
        // the LanguageModelSession(instructions:) initializer. Per-turn varying context (search, RAG, attached
        // files for *this* question) must be supplied by the caller inside the `prompt` (or history string).
        // This is what allows real transcript state to be kept by the framework across normal follow-ups.
        let baseForSession = baseInstructionsForSession(instructions)
        let newHash = baseForSession.hashValue
        let shouldRecreate = currentSession == nil || (!baseForSession.isEmpty && newHash != lastInstructionsHash)
        if shouldRecreate {
            if !baseForSession.isEmpty {
                currentSession = LanguageModelSession(instructions: baseForSession)
            } else {
                currentSession = LanguageModelSession()
            }
            lastInstructionsHash = newHash
        }

        guard let session = currentSession else {
            throw NSError(domain: "Searxly.LocalAI", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to create LanguageModelSession"])
        }

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
            Log.ai.info("[LocalAI] Plain respond (no tools) — prompt len: \(prompt.count)")
        }

        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            // On token limit errors the LanguageModelSession can be left in a bad state for the next turn.
            // Clearing it forces a fresh session on the subsequent request (cheap to recreate).
            let desc = (error as NSError).localizedDescription
            if desc.contains("maximum allowed") || desc.contains("tokens") || desc.contains("4096") {
                currentSession = nil
                lastInstructionsHash = nil
            }
            throw error
        }
        #else
        throw NSError(domain: "Searxly.LocalAI", code: -11, userInfo: [NSLocalizedDescriptionKey: "FoundationModels framework not present at compile time"])
        #endif
    }

    func generateStream(prompt: String, instructions: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    #if canImport(FoundationModels)
                    // Reuse or create session (same logic as non-streaming for consistency).
                    // Use stable base contract only (see generate() for full rationale).
                    let baseForSession = baseInstructionsForSession(instructions)
                    let newHash = baseForSession.hashValue
                    let shouldRecreate = currentSession == nil || (!baseForSession.isEmpty && newHash != lastInstructionsHash)
                    if shouldRecreate {
                        if !baseForSession.isEmpty {
                            currentSession = LanguageModelSession(instructions: baseForSession)
                        } else {
                            currentSession = LanguageModelSession()
                        }
                        lastInstructionsHash = newHash
                    }

                    guard let session = currentSession else {
                        continuation.finish(throwing: NSError(domain: "Searxly.LocalAI", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to create LanguageModelSession"]))
                        return
                    }

                    // Real streaming from Apple Intelligence when available.
                    // The API often yields cumulative content, so we compute deltas to avoid
                    // repeating previous text in the bubble (which was causing mangled repeated outputs).
                    // FIX: use common prefix length (robust to small rephrases or non-strict appends)
                    // instead of blind dropFirst(count). Also reset on non-prefix to avoid total garbage.
                    var previousContent = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let current = partial.content
                        if !current.hasPrefix(previousContent) {
                            // Unexpected non-extension; start fresh from this partial to avoid
                            // producing garbage deltas. Still better than dropping the turn.
                            previousContent = ""
                        }
                        if current.count > previousContent.count {
                            let delta = String(current.dropFirst(previousContent.count))
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            previousContent = current
                        }
                    }
                    #else
                    let full = try await generate(prompt: prompt, instructions: instructions)
                    continuation.yield(full)
                    #endif

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func unload() async {
        currentSession = nil
        lastInstructionsHash = nil
        #if canImport(FoundationModels)
        currentToolAwareSession = nil
        #endif
        // In a real implementation we would release the LanguageModelSession here.
    }

    #if canImport(FoundationModels)
    private var currentToolAwareSession: LanguageModelSession?

    /// Native tools path. When `tools` is non-nil we create (or reuse) a LanguageModelSession
    /// with the tools registered. The framework + model will invoke Tool.call (bound to real
    /// private Searxly actions in the caller) when the model decides to use a tool. The returned
    /// content is the final natural-language response after tool results have been incorporated.
    /// Session reuse follows similar logic to the plain path (recreate on base contract change).
    func generate(prompt: String, instructions: String?, tools: [any Tool]?) async throws -> String {
        guard let tools, !tools.isEmpty else {
            return try await generate(prompt: prompt, instructions: instructions)
        }

        // For tool-aware turns we maintain a separate session so the framework can keep
        // the full agentic transcript (previous tool results, etc.). We still honor the
        // "recreate only on material instructions change" discipline for the base contract.
        // Use the same stable base (stripped of per-turn RAG/search/files) as the plain path.
        let baseForSession = baseInstructionsForSession(instructions)
        let newHash = baseForSession.hashValue
        let shouldRecreate = currentToolAwareSession == nil || (!baseForSession.isEmpty && newHash != lastInstructionsHash)

        if shouldRecreate {
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Creating new tool-aware LanguageModelSession (tools: \(tools.count), instructions len: \(instructions?.count ?? 0))")
            }
            if !baseForSession.isEmpty {
                currentToolAwareSession = LanguageModelSession(tools: tools, instructions: baseForSession)
            } else {
                currentToolAwareSession = LanguageModelSession(tools: tools)
            }
            lastInstructionsHash = newHash
        }

        guard let session = currentToolAwareSession else {
            throw NSError(domain: "Searxly.LocalAI", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to create tool-aware LanguageModelSession"])
        }

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
            Log.ai.info("[LocalAI] Calling session.respond(to:) for native tools (prompt len: \(prompt.count))")
        }

        do {
            let response = try await session.respond(to: prompt)
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Native tools respond completed, content len: \(response.content.count)")
            }
            return response.content
        } catch {
            let desc = (error as NSError).localizedDescription
            if desc.contains("maximum allowed") || desc.contains("tokens") || desc.contains("4096") {
                currentToolAwareSession = nil
                lastInstructionsHash = nil
            }
            throw error
        }
    }
    #endif
}