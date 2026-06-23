//
//  LocalAIChatSheet+Messaging.swift
//  Searxly
//
//  Send/stream pipeline, tool confirmation execution, and follow-up generation.
//

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which model backend the Local AI chat is currently driving.
enum ChatBackendChoice {
    case apple
    case ollama
    case searxly
}

extension LocalAIChatSheet {

    /// The backend the chat is currently using, derived from preferences.
    var activeBackend: ChatBackendChoice {
        if manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI { return .searxly }
        if manager.preferences.experimentalFallbacksEnabled && manager.preferences.useOllama { return .ollama }
        return .apple
    }

    /// Human-readable label for the active backend (used to tag conversations).
    var currentBackendDescription: String {
        switch activeBackend {
        case .searxly: return "Searxly AI (\(manager.preferences.searxlyAIModelName))"
        case .ollama:  return "Ollama (\(manager.preferences.ollamaModelName))"
        case .apple:   return "On-device (Apple Intelligence)"
        }
    }

    func switchModel(to backend: ChatBackendChoice) {
        if activeBackend == backend { return }

        switch backend {
        case .apple:
            manager.preferences.useSearxlyAI = false
            manager.preferences.useOllama = false
        case .ollama:
            guard manager.preferences.experimentalFallbacksEnabled else { return }
            manager.preferences.useOllama = true
            manager.preferences.useSearxlyAI = false
        case .searxly:
            guard manager.preferences.searxlyAIEnabled else { return }
            manager.preferences.useSearxlyAI = true
            manager.preferences.useOllama = false
        }
        manager.persistPreferences()

        messages.removeAll()
        attachedSearchContext = nil
        attachedFiles.removeAll()
        customInstructions = ""
        currentFollowUpSuggestions = []
        pendingToolRequest = nil
        safelyResetAIState()

        let newBackend = currentBackendDescription
        LocalIntelligenceManager.shared.startNewLocalAIChat(backendDescription: newBackend)
        LocalIntelligenceManager.shared.reselectProvider()

        let active = LocalIntelligenceManager.shared.getActiveLocalAIConversation(backendDescription: newBackend)
        messages = active.messages

        messages.append(ChatMessage(role: .system, text: "Switched to \(newBackend). New conversation started."))
        syncCurrentConversation(backendDesc: newBackend)
    }

    /// Starts a fresh conversation, clearing local UI state and telling the manager.
    /// Used by the header button and the conversations list.
    func startNewConversation() {
        let backendDesc = currentBackendDescription

        LocalIntelligenceManager.shared.startNewLocalAIChat(backendDescription: backendDesc)

        messages.removeAll()
        attachedSearchContext = nil
        attachedFiles.removeAll()
        customInstructions = ""
        currentFollowUpSuggestions = []
        pendingToolRequest = nil
        safelyResetAIState()
    }

    func seedIfNeeded() {
        // Load the active conversation from the history list (supports previous conversations + per-session/permanent).
        let backendDesc = currentBackendDescription

        let active = manager.getActiveLocalAIConversation(backendDescription: backendDesc)
        if messages.isEmpty && !active.messages.isEmpty {
            messages = active.messages
        }

        if messages.isEmpty && manager.canUseFeatures {
            let base = "On-device chat is ready. Ask me anything. For questions about people, companies, tech, events or facts I will use the private web_search tool (your own SearXNG) and give you the answer in the chat. Use the 'Web search' chip for fresh research or 'Open site…' when you explicitly want the browser to navigate. Only two work tools are available."
            let filesNote = " Use the paperclip or drag files (PDF, text, Markdown) to give me your own notes privately — they stay only in this chat."
            let instructionsNote = customInstructions.isEmpty ? "" : " Custom instructions are active for this chat (tap the Instructions button to edit)."
            messages.append(ChatMessage(role: .system, text: base + filesNote + instructionsNote))

            // Make sure the newly created empty conversation (if any) is up to date in the list.
            syncCurrentConversation(backendDesc: backendDesc)
        }

        // If we were opened (or are open) with an "Ask Searxly AI" selection, act on it now.
        consumePendingSeed()
    }

    /// Handles a pending "Ask Searxly AI" seed. Three cases:
    /// - Handoff from the quick-answer popup (priorAnswer set): inject the Q&A so the chat continues.
    /// - Ask: pre-fill the composer so the user can frame a question.
    /// - Explain/Summarize (only if seeded directly): auto-send.
    /// Clears the seed so it's consumed exactly once.
    func consumePendingSeed() {
        guard let s = seed.wrappedValue else { return }
        seed.wrappedValue = nil

        let selection = s.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return }

        // Quick-answer handoff: show the prior exchange, then let the user continue.
        if let answer = s.priorAnswer, !answer.isEmpty {
            messages.append(ChatMessage(role: .user, text: questionText(for: s.action, selection: selection)))
            messages.append(ChatMessage(role: .assistant, text: answer))
            currentFollowUpSuggestions = []
            syncCurrentConversation()
            return
        }

        switch s.action {
        case .ask:
            // Pre-fill the composer with the quoted selection; let the user type their question.
            inputText = "Regarding this text:\n\n\"\(selection)\"\n\n"
        case .explain, .summarize:
            inputText = questionText(for: s.action, selection: selection)
            send()
        case .summarizePage:
            // Only reached via handoff (handled above). Defensive: just pre-fill, never auto-send
            // (we don't have the page body here — and must never re-introduce untrusted page text).
            inputText = "About this page (\(selection)): "
        }
    }

    /// The user-facing question text used for a selection action (also the transcript line on handoff).
    /// For a page summary, `selection` is the page TITLE only — never the raw page body.
    func questionText(for action: AIChatSeed.Action, selection: String) -> String {
        switch action {
        case .summarize:     return "Summarize this:\n\n\"\(selection)\""
        case .explain:       return "Explain this clearly and concisely:\n\n\"\(selection)\""
        case .ask:           return "Regarding this text:\n\n\"\(selection)\""
        case .summarizePage: return "Summarize this page: \(selection)"
        }
    }

    /// Decides whether to spend time on RAG retrieval for this query.
    /// For Apple Intelligence (small model) we are aggressive (RAG helps a lot).
    /// For Ollama we are lazy: only retrieve if the query looks like it needs the user's personal history/bookmarks
    /// (e.g. "what did I read about X", "my bookmark", "have I visited"). General knowledge questions ("who is Elon Musk")
    /// skip RAG entirely for Ollama — the stronger model can answer from knowledge + web_search tool when appropriate.
    func shouldRetrieveRAG(for query: String, isOllama: Bool, isCloud: Bool = false) -> Bool {
        guard retrieveRAG != nil else { return false }
        // Aggressive RAG ONLY for the on-device Apple model: it's free and nothing leaves the Mac.
        // For any backend that sends prompts off-device — the experimental remote Ollama AND the
        // Searxly AI cloud — gate RAG behind the personal-intent heuristic below, so private
        // bookmarks/history/notes never leave the device for general-knowledge questions
        // (e.g. "who is elon musk" must NOT ship your browsing history to the cloud).
        if !isOllama && !isCloud { return true }

        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return false }

        // Heuristics for "personal / memory" queries
        let personalTriggers = [
            "my ", "i ", "i've ", "i have ", "what i", "have i", "did i", "my history", "bookmarks", "bookmark",
            "saved", "visited", "read about", "remember", "previously", "earlier", "last time", "my notes",
            "what did i", "have i read", "my last", "i bookmarked", "i visited", "i saved"
        ]
        if personalTriggers.contains(where: { lower.contains($0) }) { return true }

        // Explicit mentions of personal data concepts
        if lower.contains("history") || lower.contains("bookmark") || lower.contains("rag") || lower.contains("memory") {
            return true
        }

        return false
    }

    /// Appends an assistant response and (cheaply) generates 2-3 tiny follow-up suggestions
    /// using the on-device model. Suggestions are only shown under the latest assistant message
    /// to keep the UI extremely compact (Grok-style).
    func appendAssistantAndSuggest(_ text: String) {
        // Apply centralized post-processing before showing final response
        let context = PostProcessingContext(
            hasCustomInstructions: !customInstructions.isEmpty,
            usedTools: false,
            isToolFollowUp: false,
            isSuggestion: false,
            lowMemoryMode: manager.preferences.lowMemoryMode
        )
        let polished = ResponsePostProcessor.process(text, context: context)

        let msg = ChatMessage(role: .assistant, text: polished)
        messages.append(msg)
        currentFollowUpSuggestions = [] // clear previous

        // Generate suggestions in the background — very low cost (short context).
        // Skip in low-memory mode to save a tiny bit of work.
        if !manager.preferences.lowMemoryMode {
            Task {
                do {
                    let recent = buildTinyContextForSuggestions()
                    let suggs = try await conversationEngine.suggestFollowUpPrompts(
                        recentContext: recent,
                        lastAssistantResponse: polished
                    )
                    await MainActor.run {
                        currentFollowUpSuggestions = suggs
                    }
                } catch {
                    // Silent fail is fine — suggestions are a nice-to-have, not critical.
                }
            }
        }
    }

    /// Streams a generation into a new assistant message bubble for live "typing" effect.
    /// Applies centralized post-processing on completion.
    /// This greatly improves perceived speed and the feeling that the AI is "talking".
    func streamAssistantResponse(
        using stream: AsyncThrowingStream<String, Error>,
        afterSystemNote: String? = nil,
        adoptThinkingId: UUID? = nil
    ) async {
        // If a thinking placeholder was already appended by the caller (main send path), adopt its id
        // so we stream into / replace that one instead of adding a duplicate bubble.
        // Otherwise (e.g. post-tool follow-ups in runFollowUpGeneration) create + append a fresh one here.
        let streamingId: UUID
        if let adopt = adoptThinkingId {
            streamingId = adopt
            await MainActor.run {
                currentFollowUpSuggestions = []
            }
        } else {
            let placeholder = ChatMessage(role: .assistant, text: "Thinking…")
            streamingId = placeholder.id
            await MainActor.run {
                messages.append(placeholder)
                currentFollowUpSuggestions = []
            }
        }

        var accumulated = ""
        var lastPushedLen = 0
        // Coalesce small deltas to reduce per-token layout thrash on the complex overlay + WebView host.
        // On high-performance hardware (M4 Pro 24 GB etc.) we push a little more frequently for
        // snappier "typing" perception without destroying responsiveness.
        // Smaller delta = snappier token-by-token feel (closer to raw `ollama run` or terminal).
        // Larger values were tuned for the tiny Apple on-device model + heavy SwiftUI updates.
        // For Ollama we bias toward lower latency updates.
        let isOllama = manager.preferences.experimentalFallbacksEnabled && manager.preferences.useOllama
        let minDeltaForUI: Int = isOllama ? 2 : (manager.isHighPerformanceDevice ? 5 : 10)

        do {
            for try await token in stream {
                if accumulated.isEmpty {
                    // First real token: replace the "Thinking..." text
                    accumulated = token
                } else {
                    accumulated += token
                }

                let shouldPush = (accumulated.count - lastPushedLen >= minDeltaForUI) || token.contains("\n") || token.contains(". ")

                if shouldPush {
                    lastPushedLen = accumulated.count
                    // Defer the @State mutation + scroll request to after the *current* layout pass.
                    // This is critical on Xcode 27 beta + complex overlay + WebViews underneath.
                    let snap = accumulated
                    let ts = messages.last(where: { $0.id == streamingId })?.timestamp ?? Date()
                    DispatchQueue.main.async {
                        if let index = messages.lastIndex(where: { $0.id == streamingId }) {
                            let updated = ChatMessage(
                                id: streamingId,
                                role: .assistant,
                                text: snap,
                                timestamp: ts
                            )
                            messages[index] = updated
                            // scroll is also deferred inside safeScrollToBottom
                        }
                    }
                }
            }

            // On finish: apply centralized smarter post-processing
            let context = PostProcessingContext(
                hasCustomInstructions: !customInstructions.isEmpty,
                usedTools: afterSystemNote != nil,
                isToolFollowUp: afterSystemNote != nil,
                isSuggestion: false,
                lowMemoryMode: manager.preferences.lowMemoryMode
            )

            let finalText = ResponsePostProcessor.process(accumulated, context: context)

            // Defer final state mutations (and the suggestions background task kickoff) to avoid
            // reentrant layout while the ScrollView / overlay / parent NSHostingView may still be
            // settling from the last streaming updates.
            DispatchQueue.main.async {
                if let index = messages.lastIndex(where: { $0.id == streamingId }) {
                    let finalMsg = ChatMessage(
                        id: streamingId,
                        role: .assistant,
                        text: finalText,
                        timestamp: messages[index].timestamp
                    )
                    messages[index] = finalMsg
                }

                isThinking = false
                syncCurrentConversation()

                // Now generate the tiny follow-up suggestions (non-streaming, cheap)
                if !manager.preferences.lowMemoryMode {
                    Task {
                        do {
                            let recent = buildTinyContextForSuggestions()
                            let suggs = try await conversationEngine.suggestFollowUpPrompts(
                                recentContext: recent,
                                lastAssistantResponse: finalText
                            )
                            await MainActor.run {
                                currentFollowUpSuggestions = suggs
                            }
                        } catch { }
                    }
                }
            }

        } catch {
            let errDesc = (error as NSError).localizedDescription
            if errDesc.contains("maximum allowed") || errDesc.contains("tokens") || errDesc.contains("4096") {
                // Token limit recovery: trim history aggressively and surface a helpful note.
                // The user can continue immediately; the next send() will see the shorter transcript.
                DispatchQueue.main.async {
                    if messages.count > 6 {
                        let toKeep = Array(messages.suffix(5))
                        messages = toKeep
                    }
                    if let index = messages.lastIndex(where: { $0.id == streamingId }) {
                        let note = ChatMessage(
                            id: streamingId,
                            role: .assistant,
                            text: "Context limit reached for the on-device model. Older turns were dropped so we can continue. What would you like to ask next?",
                            timestamp: messages[index].timestamp
                        )
                        messages[index] = note
                    }
                    safelyResetAIState()
                }
            } else {
                DispatchQueue.main.async {
                    if let index = messages.lastIndex(where: { $0.id == streamingId }) {
                        let errorMsg = ChatMessage(
                            id: streamingId,
                            role: .assistant,
                            text: "I ran into a problem while responding. Want to try again?",
                            timestamp: messages[index].timestamp
                        )
                        messages[index] = errorMsg
                    }
                    safelyResetAIState()
                }
            }
        }
    }

    /// Builds a very small context string for follow-up suggestion generation.
    /// Keeps the extra prompt tiny so it doesn't impact latency or context budget.
    /// High-perf devices get a slightly richer window (still tiny).
    func buildTinyContextForSuggestions() -> String {
        let window = manager.isHighPerformanceDevice ? 7 : 5
        var ctx = ""
        for m in messages.suffix(window) where m.role != .system {
            let speaker = m.role == .user ? "User" : "Assistant"
            let short = String(m.text.prefix(120))
            ctx += "\(speaker): \(short)\n"
        }
        return ctx
    }

    func attachCurrentSearch() {
        if !lastSearchQuery.isEmpty {
            attachedSearchContext = "Search: \u{201C}\(lastSearchQuery)\u{201D} \u{2014} answers will be grounded in the results."
        } else {
            attachedSearchContext = "No recent search. Run a search from the address bar first for the best grounded answers."
        }
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, manager.canUseFeatures, !isThinking else { return }

        // Smart handling for tool confirmation: if user says "yes"/"ok" etc. while a tool request is pending,
        // auto-confirm instead of sending the affirmation to the model.
        if let pending = pendingToolRequest {
            let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if lower == "yes" || lower == "y" || lower == "ok" || lower == "sure" || lower == "go ahead" || lower == "yeah" || lower == "please" {
                messages.append(ChatMessage(role: .user, text: text))
                inputText = ""
                confirmToolUse(pending)
                return
            } else {
                pendingToolRequest = nil
            }
        }

        messages.append(ChatMessage(role: .user, text: text))
        inputText = ""
        currentFollowUpSuggestions = [] // hide old suggestions when user replies
        isThinking = true

        // Keep the active conversation in the history list in sync.
        syncCurrentConversation()

        // Diagnostics: log send start with key context
        let _canUseTools = (performPrivateSearch != nil || openWebsite != nil) && manager.canUseFeatures
        let _useTools = manager.toolsEnabled && _canUseTools
        let isOllamaForLog = manager.preferences.experimentalFallbacksEnabled && manager.preferences.useOllama
        let isCloudForLog = manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI
        let ragAttempted = shouldRetrieveRAG(for: text, isOllama: isOllamaForLog, isCloud: isCloudForLog)
        LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Chat send started (len=\(text.count))", detail: "useToolsInPrompt=\(_useTools), toolsEnabled=\(manager.toolsEnabled), attachedFiles=\(attachedFiles.count), rag=\(ragAttempted)", usedModel: true)

        // Reliable direct bypass for explicit navigation ("open ...", "go to ...").
        // Because we now have only one navigation tool (open_website), any clear "I want to see the page"
        // command is handled immediately here without involving the model or the tool-calling machinery.
        // This is the most robust path for the "open tesla official website" use case.
        //
        // Uses the hardened AgenticTools.isExplicitNavigationCommand (includes question/info-request
        // rejection per the plan + Apple-style safeguards). "can you open elon musk's official chip facility..."
        // and similar will NOT bypass — they go through normal generation where the classification gate +
        // rules force web_search + answer-in-chat.
        if AgenticTools.isExplicitNavigationCommand(text) {
            if let opener = openWebsite {
                // Defer dismissal + action (re-entrancy safety on the custom overlay + WebView host).
                isThinking = false
                DispatchQueue.main.async {
                    isPresented = false
                    MainActor.assumeIsolated {
                        opener(text)
                    }
                }
                return
            }
        }

        // Normal generation. The heavy lifting for "be a normal chatbot and answer knowledge questions directly"
        // now lives in the system instructions (AIRules.coreContract + knowledgeFirst + actionUsage + navigationRule).
        // The per-turn prompt here stays minimal and clean.
        let canUseTools = (performPrivateSearch != nil || openWebsite != nil) && manager.canUseFeatures
        let useToolsInPrompt = manager.toolsEnabled && canUseTools

        let maxHistoryTurns = manager.preferences.lowMemoryMode ? 4 : (manager.isHighPerformanceDevice ? 14 : 8)
        let history = conversationEngine.buildHistoryString(from: messages, maxTurns: maxHistoryTurns)

        let prompt: String
        if useToolsInPrompt {
            // Native tool path (when the user has opted into AI-proposed actions).
            // The rules tell the model: for informational questions ("who is", facts, companies, tech, events...),
            // proactively call web_search using the user's private SearXNG so it can
            // fetch fresh data and synthesize a good answer in the chat.
            // Only use open/navigation tools for explicit "open the page / go to the site" commands.
            // The UI action buttons are always available for the user to trigger directly.
            let hist = history.isEmpty ? "" : history + "\n\n"
            prompt = hist + "User: \(text)"
        } else {
            // Marker / confirmation path (tools toggle off or first-time explicit).
            // The main rules (including permission to answer general knowledge questions directly) are in the system instructions.
            prompt = history +
                "User: \(text)\n\n" +
                "Follow the rules and identity from the system instructions. Answer directly from general knowledge for well-known topics. Only refuse or ask for a search when the question is about genuinely current events or something truly outside your knowledge and the provided context.\nAssistant:"
        }

        // Show a visible "thinking" bubble immediately after the user message (and after prompt prep) for all normal generations.
        // This guarantees the user always sees the AI is active ("thinking"), addressing "not even thinking".
        // The model prompt above was built from the clean transcript (no UI artifact included).
        let thinkingPlaceholder = ChatMessage(role: .assistant, text: "Thinking…")
        let thinkingId = thinkingPlaceholder.id
        messages.append(thinkingPlaceholder)

        // Launch work on @MainActor so that sync calls into @MainActor types (ConversationEngine, the retrieveRAG
        // closure which hits LocalIntelligenceManager, prepareSystemPrompt, etc.) and any mutations to @State messages
        // or @Observable manager state are always performed on the correct executor. This prevents cross-thread
        // mutation crashes / Observation violations that can occur when a plain Task runs the prep from a background
        // thread (the actual inference inside generate/respond is async and yields).
        Task { @MainActor in
            let isOllama = manager.preferences.experimentalFallbacksEnabled && manager.preferences.useOllama
            let ollamaName: String? = isOllama ? manager.preferences.ollamaModelName : nil
            let isCloud = manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI

            // RAG is lazy for Ollama (see shouldRetrieveRAG below). This avoids the cost of embedding the
            // query + scoring against history/bookmarks for general-knowledge questions (the original source
            // of the "IP address history leaking into 'who is elon musk'" bug). Apple path remains eager.
            var ragItems: [RAGItem] = []
            if shouldRetrieveRAG(for: text, isOllama: isOllama, isCloud: isCloud) {
                if let retriever = retrieveRAG, !text.isEmpty {
                    ragItems = await retriever(text)
                }
            }

            var systemPrompt = conversationEngine.prepareSystemPrompt(
                withSearchContext: attachedSearchContext,
                ragItems: ragItems,
                attachedFilesCount: attachedFiles.count,
                toolsEnabled: useToolsInPrompt,
                customInstructions: customInstructions.isEmpty ? nil : customInstructions,
                usingOllama: isOllama,
                isCloud: isCloud,
                ollamaModelName: ollamaName
            )

            // FIX (P2): actually inject the extracted text from user-attached local files (PDF/text/md).
            // Previously fileContextBlockForPrompt() existed and was documented as "called from send()"
            // but was never invoked — the model only ever saw the count header, never the content.
            // The header is already in systemPrompt (via prepare); we append the full block (header
            // + excerpts) here for the actual bytes the user chose. Harmless duplicate of the short
            // header rule. This is the key fix for "attach my notes + ask about them + web search".
            if !attachedFiles.isEmpty {
                // Header rule already added by prepareSystemPrompt via attachedFilesCount; only add the actual excerpts here.
                systemPrompt += fileContextBlockForPrompt(includeHeader: false)
            }

            // Companion to the stable base instructions change in AppleIntelligenceProvider:
            // Make sure the *current turn's* private grounding (fresh RAG for this query, attached files note,
            // search context) is visible in the user-side `prompt` that goes to respond(to:), not only in the
            // (now stripped for reuse) system instructions. This guarantees the model sees the data even when
            // the LanguageModelSession is reused across turns.
            var effectivePrompt = prompt

            // Token budget guard for per-turn injected context (search + RAG + files).
            // Even with good history truncation, these can push the total (instructions + history + this)
            // over the hard ~4096 token limit of the on-device Apple Intelligence model.
            // We dynamically trim here so the user doesn't hit the error after a few turns.
            let approxSystemTokens = systemPrompt.count / 3
            let approxHistoryTokens = effectivePrompt.count / 3
            let remainingForTurnCtx = max(400, 3800 - approxSystemTokens - approxHistoryTokens) // conservative headroom

            if !ragItems.isEmpty || !attachedFiles.isEmpty || (attachedSearchContext != nil && !(attachedSearchContext?.isEmpty ?? true)) {
                var turnCtx = "\n\n[This-turn private context — titles/URLs/dates + short snippets only; attached files have full excerpts in system instructions for this turn]"

                if let sc = attachedSearchContext, !sc.isEmpty {
                    // Truncate search context if budget is tight
                    let searchPart = "\nSearch: \(sc)"
                    if searchPart.count / 3 > remainingForTurnCtx / 2 {
                        turnCtx += "\nSearch: " + String(sc.prefix(remainingForTurnCtx * 2))
                    } else {
                        turnCtx += searchPart
                    }
                }

                if !ragItems.isEmpty {
                    var ragBlock = AIPromptLibrary.ragContextBlock(items: ragItems)
                    // If RAG is too big for remaining budget, keep only the most recent/relevant few
                    if ragBlock.count / 3 > remainingForTurnCtx {
                        let keep = max(1, min(3, ragItems.count))
                        ragBlock = AIPromptLibrary.ragContextBlock(items: Array(ragItems.suffix(keep)))
                    }
                    turnCtx += "\nRelevant local (RAG):\n" + ragBlock
                }

                if !attachedFiles.isEmpty {
                    // Use tighter excerpts when context is already heavy
                    let fileNote = "\n\(attachedFiles.count) user-attached local file(s) are in the system instructions above for this turn only."
                    turnCtx += fileNote
                    // Note: the actual full excerpts were already appended to systemPrompt earlier via fileContextBlockForPrompt.
                    // The sheet already uses ChatAttachment.excerpt in some paths; we rely on that + the history trim above.
                }

                // For the legacy (marker) prompt construction the outer `prompt` may end with completion priming
                // such as "\nAssistant:". Insert the fresh per-turn context *before* any such priming so the
                // model sees the RAG/files/search data as part of the current user question rather than after
                // its own role cue (which can cause ignored context or role leakage in small on-device models).
                let primingMarkers = ["\nAssistant:", "\nassistant:", "Assistant:", "assistant:"]
                var insertionPoint = effectivePrompt.endIndex
                for m in primingMarkers {
                    if let r = effectivePrompt.range(of: m, options: [.backwards, .caseInsensitive]) {
                        insertionPoint = r.lowerBound
                        break
                    }
                }
                let prefix = String(effectivePrompt[..<insertionPoint])
                let suffix = String(effectivePrompt[insertionPoint...])
                effectivePrompt = prefix + "\n\n" + turnCtx.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + suffix
            }

            if useToolsInPrompt && isCloud {
                // Cloud agentic path: real OpenAI-style tool calling on the 70B (web_search /
                // open_website), returning a grounded answer + clickable source citations.
                // Kept separate from the Apple FoundationModels path (which uses @Generable tools).
                await runCloudAgenticTurn(effectivePrompt: effectivePrompt,
                                          systemPrompt: systemPrompt,
                                          thinkingId: thinkingId)
                return
            }

            if useToolsInPrompt {
                LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Entering native tools path", detail: "tools count will be built now", usedModel: true)

                // Native tool calling path (WWDC26 Foundation Models Tool + Generable) when the toggle is on.
                // We construct live Tool instances bound to the real private closures (BrowserState + SearXNGService).
                // The provider creates a LanguageModelSession(tools: ...) ; if the model calls a tool the
                // framework invokes the Tool.call (which performs the private action and returns a result string).
                // The returned reply is already the final natural response (after tool results were seen by the model).
                // This gives reliable structured args and agentic behavior while keeping all privacy / logging / "your private SearXNG only" guarantees.
                //
                // When the toggle is off we fall back to the classic prompt + TOOL_REQUEST marker path + confirmation card (existing behavior).

                let reply: String
                do {
                    // Build the current (exactly two) tool set when the user has opted into AI-proposed actions.
                    // We now delegate entirely to the new per-tool files under LocalAI/AgenticTools/.
                    // Each tool file owns its native Tool/Generable, description (with "when NOT to use" guidance),
                    // and the shape of the compact result string the model will see.
                    let ps = self.performPrivateSearch
                    let ow = self.openWebsite

                    let currentTools: [any Tool]?
                    #if canImport(FoundationModels)
                    if manager.toolsEnabled {
                        currentTools = AgenticTools.makeCurrent(
                            webSearch: { @Sendable q async in
                                guard let searcher = ps else { return "No private search available." }
                                // Ensure the user's private SearXNG (local or remote) is ready.
                                // The dance below is the proven pattern that avoids MainActor/Sendable
                                // re-entrancy issues on the current Xcode 27 beta + FoundationModels.
                                DispatchQueue.main.async {
                                    Task {
                                        let mgr = LocalSearxngManager.shared
                                        if mgr.projectFolderExists {
                                            if await mgr.isLocalWebReady() {
                                                await mgr.refreshStatus()
                                            } else {
                                                await mgr.ensureReadyAndRunning()
                                            }
                                        }
                                    }
                                }
                                // Reduced/conditional grace period for better perceived speed (especially on M4 Pro 24 GB+).
                                // If the SearXNG manager already reports running we give only a small head-start.
                                // Must hop to @MainActor because LocalSearxngManager is @MainActor-isolated.
                                let isRunning = await MainActor.run { LocalSearxngManager.shared.status == .running }
                                let sleepMs: UInt64 = isRunning ? 180 : 650
                                try? await Task.sleep(for: .milliseconds(sleepMs))
                                let results = await searcher(q)
                                guard !results.isEmpty else { return "No results from your private SearXNG instance(s)." }
                                // Higher-quality structured results for the on-device model (easier for small model to parse and cite).
                                return results.prefix(5).enumerated().map { idx, r in
                                    let num = idx + 1
                                    let snip = (r.content ?? "").prefix(220)
                                    return "[\(num)] \(r.title)\nURL: \(r.url)\nSnippet: \(snip)"
                                }.joined(separator: "\n\n")
                            },
                            openWebsite: { @Sendable desc async in
                                guard let opener = ow else { return "Cannot open site." }
                                // openWebsite (and tab creation) must happen on the main actor.
                                await MainActor.run {
                                    opener(desc)
                                }
                                return "Opened the requested site via your private SearXNG."
                            },
                            logToolUse: { @Sendable name, detail in
                                Task {
                                    await MainActor.run {
                                        LocalIntelligenceManager.shared.logAction(.toolUse, summary: "Native tool: \(name)", detail: detail, usedModel: true)
                                    }
                                }
                            }
                        )
                    } else {
                        currentTools = nil
                    }
                    #else
                    currentTools = nil
                    #endif

                    LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Calling native generate with tools", detail: "promptLen=\(effectivePrompt.count), systemLen=\(systemPrompt.count), tools=\(currentTools?.count ?? 0)", usedModel: true)
                    reply = try await conversationEngine.generate(prompt: effectivePrompt, instructions: systemPrompt, tools: currentTools)
                    LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Native generate returned", detail: "replyLen=\(reply.count)", usedModel: true)
                } catch {
                    let errDesc = error.localizedDescription
                    LocalIntelligenceManager.shared.logAction(.error, summary: "Native tools generate failed", detail: "\(error)", usedModel: true)

                    if errDesc.contains("maximum allowed") || errDesc.contains("tokens") || errDesc.contains("4096") {
                        // Auto-recovery for the common context window overflow (after a few turns with heavy RAG/search/files).
                        // Trim in-memory history to the most recent turns so the next (and this) generation can succeed.
                        DispatchQueue.main.async {
                            if messages.count > 6 {
                                // Keep the last user + assistant pair + a couple more; drop the rest.
                                let toKeep = Array(messages.suffix(5))
                                messages = toKeep
                            }
                        }
                        // Add a visible note and try one more time with the now-smaller context.
                        // We fall through to returning a clear message; the user can immediately send again
                        // and it will use the trimmed transcript.
                        reply = "Context limit reached for the on-device model (~4,096 tokens total). I dropped older turns automatically. Please try your last question again."
                    } else {
                        reply = "On-device generation encountered an error: \(errDesc). Ensure Apple Intelligence (or your chosen fallback) is ready."
                    }
                }

                // Beta workaround (Xcode 27 / current Foundation Models on-device):
                // The model can still emit a plain-text tool request (e.g. `web_search "..."` or `open_website "..."`)
                // instead of letting the framework run the bound Tool.call. We detect and auto-execute the
                // two work tools so the user gets a proper synthesized answer or navigation instead of raw call text.
                if let (toolName, payload) = parseToolRequest(from: reply) {
                    LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Native tools reply was a tool request text — auto-executing", detail: "\(toolName): \(payload)")
                    let req = PendingToolRequest(toolName: toolName, payload: payload)
                    confirmToolUse(req, auto: manager.toolsEnabled)
                    return
                }

                // Additional bare tool name detection (the small on-device model sometimes emits the tool name
                // as text even on the native path). Only the two remaining work tools are recognized.
                let lowerReply = reply.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let bareToolMap: [String: String] = [
                    AgenticTools.webSearchMarker: AgenticTools.webSearchMarker,
                    AgenticTools.openWebsiteMarker: AgenticTools.openWebsiteMarker
                ]
                if parseToolRequest(from: reply) == nil {
                    for (key, canonical) in bareToolMap {
                        if lowerReply.hasPrefix(key) || lowerReply.hasPrefix(key + " ") || lowerReply.contains(" " + key) || lowerReply == key {
                            var payload = reply
                            if let range = reply.range(of: key, options: .caseInsensitive) {
                                payload = String(reply[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            if (payload.hasPrefix("\"") && payload.hasSuffix("\"")) || (payload.hasPrefix("'") && payload.hasSuffix("'")) {
                                payload = String(payload.dropFirst().dropLast())
                            } else if payload.hasPrefix("\"") || payload.hasPrefix("'") {
                                payload = String(payload.dropFirst())
                            }
                            let req = PendingToolRequest(toolName: canonical, payload: payload)
                            LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Native tools reply contained bare tool name — auto-executing", detail: "\(canonical): \(payload)")
                            confirmToolUse(req, auto: manager.toolsEnabled)
                            return
                        }
                    }
                }

                // Defer the final UI mutations for the native tools path as well. Even though we are
                // on @MainActor after an await, the preceding generation + any tool side-effects (open tabs etc.)
                // + parent browser layout can leave the hosting view in a sensitive state on beta SDKs.
                let finalPolished: String = {
                    var cleaned = ResponsePostProcessor.stripPrimingAndRolePrefixesForParsing(reply)
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ResponsePostProcessor.process(cleaned.isEmpty ? "I didn't get a response. Try rephrasing." : cleaned, context: PostProcessingContext(
                        hasCustomInstructions: !customInstructions.isEmpty,
                        usedTools: true,
                        isToolFollowUp: true,
                        isSuggestion: false,
                        lowMemoryMode: manager.preferences.lowMemoryMode
                    ))
                }()

                DispatchQueue.main.async {
                    if let idx = messages.lastIndex(where: { $0.id == thinkingId }) {
                        messages.remove(at: idx)
                    }
                    messages.append(ChatMessage(role: .assistant, text: finalPolished))
                    isThinking = false
                    syncCurrentConversation()
                }
                // (Suggestions can be added cheaply later if desired; current native path keeps it minimal.)
            } else {
                LocalIntelligenceManager.shared.logAction(.chatTurn, summary: "Entering stream (no-tools) path", detail: "promptLen=\(effectivePrompt.count), systemLen=\(systemPrompt.count)", usedModel: true)
                // Normal chat turns and post-tool follow-ups: use streaming for live, natural output.
                // We pre-appended the thinking bubble (id = thinkingId) right after the user message so it is visible
                // synchronously. Adopt it here so the stream updates/replaces that exact bubble (no duplicate).
                let stream = conversationEngine.generateStream(prompt: effectivePrompt, instructions: systemPrompt)
                await streamAssistantResponse(using: stream, adoptThinkingId: thinkingId)
                // Note: streamAssistantResponse manages its own final isThinking=false and replaces the adopted placeholder by id.
            }
            // Note: All throwing generation (provider.generate) is caught locally above and turned into
            // a user-visible error string (which still removes the thinking placeholder and appends the error text).
            // streamAssistantResponse catches its own stream errors and calls safelyResetAIState() + shows a graceful message.
            // Explicit tool paths (marker mode) manage state via confirmToolUse / early returns.
        }
    }

    /// Parser for the legacy TOOL_REQUEST marker path (now only the two work tools).
    /// Looks for: TOOL_REQUEST: <toolName> "payload here"
    /// Returns (toolName, payload) or nil.
    func parseToolRequest(from text: String) -> (tool: String, payload: String)? {
        guard let marker = text.range(of: "TOOL_REQUEST:", options: .caseInsensitive) else {
            // Also support the older lowercase variant the prompt sometimes emits
            guard let marker2 = text.range(of: "tool_request:", options: .caseInsensitive) else { return nil }
            return parseAfterMarker(text, marker: marker2)
        }
        return parseAfterMarker(text, marker: marker)
    }

    func parseAfterMarker(_ text: String, marker: Range<String.Index>) -> (tool: String, payload: String)? {
        let after = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // First token is the tool name (e.g. web_search, open_website, ...)
        let tokens = after.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return nil }
        let tool = String(tokens[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var payload = tokens.count > 1 ? String(tokens[1]) : ""
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // Improved quote stripping (P4): prefer content *inside* the first matching pair.
        // Supports "..." or '...' even if the payload contains the other quote char.
        if let firstQuote = payload.first, (firstQuote == "\"" || firstQuote == "'") {
            let endSearch = payload.dropFirst()
            if let endIdx = endSearch.firstIndex(of: firstQuote) {
                let inner = endSearch[..<endIdx]
                payload = String(inner)
            } else {
                // Unbalanced — take everything after the opening quote, trimmed
                payload = String(payload.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if (payload.hasPrefix("\"") && payload.hasSuffix("\"")) || (payload.hasPrefix("'") && payload.hasSuffix("'")) {
            payload = String(payload.dropFirst().dropLast())
        }

        let clean = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : (tool: tool, payload: clean)
    }

    // MARK: - Tool confirmation card UI helper (only the two work tools remain)
    func toolConfirmationDetails(for req: PendingToolRequest) -> (icon: String, headline: String, body: String, payloadLine: String, approveLabel: String) {
        // Delegate to the per-tool files so confirmation text, icons, and wording stay co-located with the tool.
        return AgenticTools.confirmationDetails(for: req.toolName, payload: req.payload)
    }

    func confirmToolUse(_ request: PendingToolRequest, auto: Bool = false, approvedNote: String? = nil) {
        let tool = request.toolName.lowercased()
        let payload = request.payload

        // Log transparently for every tool
        manager.logAction(.toolUse, summary: "AI requested \(request.toolName)", detail: payload, usedModel: true)

        pendingToolRequest = nil

        // For direct navigation actions (open site, open tabs, new private search tab),
        // we will close the chat sheet immediately after executing the action.
        // Skip adding the system note to the (now-closing) transcript to keep the UX clean.
        // The manager.logAction call above is sufficient for the activity log / audit.
        let isDirectNavigationAction = [AgenticTools.openWebsiteMarker, "open_site", "open_website"].contains(tool)
        if !isDirectNavigationAction {
            if !auto {
                let note = approvedNote ?? "I used \(request.toolName) for “\(payload)” (you approved)."
                messages.append(ChatMessage(role: .system, text: note))
            }
        }

        switch tool {
        case AgenticTools.webSearchMarker, "websearch":
            guard let search = performPrivateSearch else {
                messages.append(ChatMessage(role: .assistant, text: "Web search tool is not available right now (no SearXNG instances wired)."))
                safelyResetAIState()
                return
            }
            isThinking = true
            Task {
                let results = await search(payload)
                let toolResult: String
                if results.isEmpty {
                    toolResult = "No results found for “\(payload)”."
                } else {
                    let top = results.prefix(6).enumerated().map { idx, r in
                        let num = idx + 1
                        let snip = (r.content ?? "").prefix(220)
                        return "[\(num)] \(r.title)\nURL: \(r.url)\nSnippet: \(snip)"
                    }.joined(separator: "\n\n")
                    toolResult = "Search results for “\(payload)” (via your private SearXNG):\n\(top)"
                }
                await runFollowUpGeneration(
                    toolResult: toolResult,
                    naturalInstruction: """
                    \(AIPromptLibrary.postToolBehavior)

                    For web search results you have short snippets. Be transparent that the information comes from the private search but keep the language natural. Stick strictly to what the snippets actually say.
                    """
                )
            }

        case AgenticTools.openWebsiteMarker, "open_site":
            guard let opener = openWebsite else {
                messages.append(ChatMessage(role: .assistant, text: "I can't open websites in this session."))
                safelyResetAIState()
                return
            }
            DispatchQueue.main.async {
                opener(payload)
            }
            safelyResetAIState()
            // Defer dismissal (re-entrancy safety for the custom chat overlay on top of WebView).
            DispatchQueue.main.async { isPresented = false }
            // Browser action is the response; no follow-up generation in the (now-closed) sheet.

        default:
            messages.append(ChatMessage(role: .assistant, text: "I don't know how to use the tool “\(request.toolName)” (only web_search and open_website are supported)."))
            safelyResetAIState()
        }
    }

    // Shared helper so web + history + action tools all get the same natural post-tool generation + post-processing.
    func runFollowUpGeneration(toolResult: String, naturalInstruction: String) async {
        // Use extracted ConversationEngine for context + history prep
        let isOllama = manager.preferences.experimentalFallbacksEnabled && manager.preferences.useOllama
        let ollamaName: String? = isOllama ? manager.preferences.ollamaModelName : nil
        let isCloud = manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI

        // Same lazy RAG logic as the main send path: off-device backends (remote Ollama AND the Searxly AI
        // cloud) only retrieve on personal/memory-style follow-ups, so private data isn't shipped off-device.
        var ragItems: [RAGItem] = []
        if let lastUser = messages.last(where: { $0.role == .user })?.text, !lastUser.isEmpty {
            if shouldRetrieveRAG(for: lastUser, isOllama: isOllama, isCloud: isCloud) {
                if let retriever = retrieveRAG {
                    ragItems = await retriever(lastUser)
                }
            }
        }

        var systemPrompt = conversationEngine.prepareSystemPrompt(
            withSearchContext: attachedSearchContext,
            ragItems: ragItems,
            attachedFilesCount: attachedFiles.count,
            toolsEnabled: false,
            customInstructions: customInstructions.isEmpty ? nil : customInstructions,
            usingOllama: isOllama,
            isCloud: isCloud,
            ollamaModelName: ollamaName
        )

        // FIX (P2): ensure attached file content is present for post-tool follow-ups too
        // (e.g. "now compare what we just found on the web to my attached PDF").
        if !attachedFiles.isEmpty {
            // Header rule already added by prepareSystemPrompt; only the actual file excerpts.
            systemPrompt += fileContextBlockForPrompt(includeHeader: false)
        }

        // Mirror the send() path: make fresh RAG (and file note) visible in the follow-up prompt text
        // (pairs with the stable base instructions used for session reuse).
        var followUpPrompt: String
        let maxHistoryTurns = manager.preferences.lowMemoryMode ? 5 : (manager.isHighPerformanceDevice ? 10 : 8)
        let hist = conversationEngine.buildHistoryString(from: messages, maxTurns: maxHistoryTurns) + "Tool/action result: \(toolResult)\n\n"

        // Apply the same per-turn context budget discipline as the main send path so follow-ups after tools
        // don't immediately blow the 4096 token limit when RAG or files are present.
        if !ragItems.isEmpty || !attachedFiles.isEmpty {
            var ctx = "[This-turn private context after tool]\n"
            if !ragItems.isEmpty {
                var ragB = AIPromptLibrary.ragContextBlock(items: ragItems)
                // Keep RAG tiny in follow-ups
                if ragB.count > 600 { ragB = AIPromptLibrary.ragContextBlock(items: Array(ragItems.suffix(2))) }
                ctx += ragB + "\n"
            }
            if !attachedFiles.isEmpty { ctx += "\(attachedFiles.count) attached local file(s) — see system instructions.\n" }
            followUpPrompt = hist + ctx
        } else {
            followUpPrompt = hist
        }

        // Respect the tool-specific naturalInstruction (varied openings, directness for history fallbacks, etc.)
        // Fall back to the generic post-tool style only if no specific guidance was provided.
        // We already augmented followUpPrompt above with this-turn RAG/files for the stable-instructions + reuse fix.
        let styleGuide = naturalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !styleGuide.isEmpty {
            followUpPrompt = followUpPrompt + "\n\n" + styleGuide
        } else {
            followUpPrompt = followUpPrompt + AIPromptLibrary.postToolFollowUpInstructions(for: toolResult)
        }

        // Extra explicit closer for follow-up turns (helps the on-device model stay grounded after tool results).
        followUpPrompt += "\n\nRespond using ONLY the rules and the exact context/tool results provided above. Be literal with history titles. Do not invent details."

        // Stream the post-tool response for live updates.
        // Do not adopt; we want a fresh "Thinking..." bubble after the tool note / system message for this follow-up turn.
        let stream = conversationEngine.generateStream(prompt: followUpPrompt, instructions: systemPrompt)
        await streamAssistantResponse(using: stream, afterSystemNote: toolResult)
    }

}
