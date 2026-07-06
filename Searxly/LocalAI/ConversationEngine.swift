//
//  ConversationEngine.swift
//  Searxly
//
//  NEW FILE (Phase 3/5 extraction).
//  Thin wrapper for multi-turn chat concerns: context preparation (search + RAG + attached files),
//  transcript management helpers, prompt building, and generation routing through the current provider.
//  Keeps the heavy lifting out of the UI sheet for better testability and separation (following plan discipline).
//  The LocalAIChatSheet still owns @State for messages, pending tools, UI, etc.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// DeveloperSettings is in the same target and accessed via shared for verbose diagnostics.

@MainActor
final class ConversationEngine {

    private let manager: LocalIntelligenceManager
    private let contextManager: ConversationContextManager
    private var lastSearchContext: String?
    private var lastRAGItems: [RAGItem] = []
    private var lastAttachedFileCount: Int = 0
    private var lastHasCustomInstructions: Bool = false

    init(manager: LocalIntelligenceManager) {
        self.manager = manager
        self.contextManager = ConversationContextManager(manager: manager)
    }

    convenience init() {
        self.init(manager: .shared)
    }

    /// Prepares the full system prompt for a chat turn, injecting all available private contexts.
    /// User custom instructions (if provided) are prepended *after* the core privacy/grounding contract
    /// but the engine always ensures core rules take precedence. This keeps everything safe and local.
    func prepareSystemPrompt(
        withSearchContext searchContext: String?,
        ragItems: [RAGItem],
        attachedFilesCount: Int,
        toolsEnabled: Bool,
        customInstructions: String? = nil,
        usingOllama: Bool = false,
        isCloud: Bool = false,
        ollamaModelName: String? = nil
    ) -> String {
        lastSearchContext = searchContext
        lastRAGItems = ragItems
        lastAttachedFileCount = attachedFilesCount
        lastHasCustomInstructions = !(customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        var prompt = AIPromptLibrary.chatSystem(
            withSearchContext: searchContext,
            ragContext: ragItems.isEmpty ? nil : AIPromptLibrary.ragContextBlock(items: ragItems),
            toolsEnabled: toolsEnabled,
            usingOllama: usingOllama,
            isCloud: isCloud,
            ollamaModelName: ollamaModelName
        )

        if let instructions = customInstructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += AIPromptLibrary.userCustomInstructionsBlock(instructions: instructions)
        }

        if attachedFilesCount > 0 {
            prompt += AIPromptLibrary.attachedFilesInstructions(fileCount: attachedFilesCount)
        }

        return prompt
    }

    /// Builds a compact conversation history string for the prompt.
    /// Now delegates to ConversationContextManager for smarter, dynamic truncation
    /// based on attached files, RAG load, custom instructions, and low-memory mode.
    /// This improves both speed (smaller prompts) and output quality (less dilution).
    func buildHistoryString(from messages: [ChatMessage], maxTurns: Int = 8) -> String {
        // maxTurns is now mostly advisory; the context manager uses a real token budget
        // (plus the dynamic turn caps) to stay safely under the on-device model's ~4096 limit.
        // We reserve headroom here for the (often large) system instructions + per-turn RAG/search/files.
        let historyBudget = 2100
        return contextManager.buildHistoryString(
            from: messages,
            attachedFilesCount: lastAttachedFileCount,
            ragItemCount: lastRAGItems.count,
            hasCustomInstructions: lastHasCustomInstructions,
            tokenBudgetForHistory: historyBudget
        )
    }

    /// Performs a generation turn using the current provider (Apple or experimental fallback).
    /// Applies the prepared system prompt + history + user message.
    /// Post-processing is now centralized in ResponsePostProcessor for smarter, consistent output.
    func generate(
        prompt: String,
        instructions: String?
    ) async throws -> String {
        let provider = manager.currentIntelligenceProvider
        let raw = try await provider.generate(prompt: prompt, instructions: instructions)

        // Apply centralized post-processing (dry starters, leakage removal, style polish, etc.)
        let context = PostProcessingContext(
            hasCustomInstructions: lastHasCustomInstructions,
            usedTools: prompt.contains("Tool result") || prompt.contains("tool"),
            isToolFollowUp: false,
            isSuggestion: false,
            lowMemoryMode: manager.preferences.lowMemoryMode
        )

        return ResponsePostProcessor.process(raw, context: context)
    }

    #if canImport(FoundationModels)
    /// Tool-aware generation (only available when FoundationModels is present and the caller passes tools).
    /// Forwards to the provider's native tools path when supported.
    @available(macOS 26.0, *)
    func generate(
        prompt: String,
        instructions: String?,
        tools: [any Tool]?
    ) async throws -> String {
        let provider = manager.currentIntelligenceProvider
        let raw: String
        if let tools, !tools.isEmpty, provider.capabilities.supportsNativeTools {
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Engine: routing to native tools generate (tools=\(tools.count))")
            }
            raw = try await provider.generate(prompt: prompt, instructions: instructions, tools: tools)
        } else {
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Engine: routing to plain generate (no tools or no support)")
            }
            raw = try await provider.generate(prompt: prompt, instructions: instructions)
        }

        // Apply centralized post-processing (dry starters, leakage removal, style polish, etc.)
        let context = PostProcessingContext(
            hasCustomInstructions: lastHasCustomInstructions,
            usedTools: prompt.contains("Tool result") || prompt.contains("tool") || tools != nil,
            isToolFollowUp: false,
            isSuggestion: false,
            lowMemoryMode: manager.preferences.lowMemoryMode
        )

        return ResponsePostProcessor.process(raw, context: context)
    }
    #endif

    /// Streaming version for live token updates in the UI.
    /// Greatly improves perceived speed and the "AI is thinking/talking" experience.
    func generateStream(
        prompt: String,
        instructions: String?
    ) -> AsyncThrowingStream<String, Error> {
        let provider = manager.currentIntelligenceProvider
        return provider.generateStream(prompt: prompt, instructions: instructions)
    }

    /// Cloud-only agentic turn: lets the cloud model call the provided tools (web_search /
    /// open_website) and returns its final answer plus the sources gathered for citations.
    /// Falls back to a plain generate when the active provider isn't the cloud.
    func generateCloudWithTools(
        prompt: String,
        instructions: String?,
        tools: [CloudTool]
    ) async throws -> CloudToolResult {
        guard let cloud = manager.currentIntelligenceProvider as? CloudIntelligenceProvider else {
            let text = try await generate(prompt: prompt, instructions: instructions)
            return CloudToolResult(text: text, sources: [], toolsUsed: [])
        }

        let result = try await cloud.generateWithTools(
            systemPrompt: instructions,
            userPrompt: prompt,
            tools: tools
        )

        let context = PostProcessingContext(
            hasCustomInstructions: lastHasCustomInstructions,
            usedTools: !result.toolsUsed.isEmpty,
            isToolFollowUp: false,
            isSuggestion: false,
            lowMemoryMode: manager.preferences.lowMemoryMode,
            // Keep [n] markers so they match the clickable source chips (only meaningful when we
            // actually have sources, i.e. a web_search happened this turn).
            preserveCitations: !result.sources.isEmpty
        )
        let polished = ResponsePostProcessor.process(result.text, context: context)
        return CloudToolResult(text: polished, sources: result.sources, toolsUsed: result.toolsUsed)
    }

    /// Lightweight context summary for UI (e.g. chips).
    var contextSummary: String? {
        var parts: [String] = []
        if let ctx = lastSearchContext, !ctx.isEmpty {
            parts.append("search")
        }
        if !lastRAGItems.isEmpty {
            parts.append("RAG:\(lastRAGItems.count)")
        }
        if lastAttachedFileCount > 0 {
            parts.append("files:\(lastAttachedFileCount)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    /// Generates 2-3 tiny, natural suggested follow-up prompts based on the conversation.
    /// Keeps them very short (Grok-style) so they take almost no space.
    /// All on-device and private.
    func suggestFollowUpPrompts(recentContext: String, lastAssistantResponse: String) async throws -> [String] {
        // Tiny throwaway generation — never bill the cloud 70B for it. Borrow the on-device model when
        // chat is on cloud; if no free on-device model is available, skip suggestions entirely.
        guard let provider = manager.auxiliaryProvider() else { return [] }

        let prompt = AIPromptLibrary.followUpSuggestions(
            recentContext: recentContext,
            lastResponse: lastAssistantResponse
        )
        let raw = try await provider.generate(prompt: prompt, instructions: nil)
        let lines = raw
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { String($0) }
        return Array(lines)
    }
}