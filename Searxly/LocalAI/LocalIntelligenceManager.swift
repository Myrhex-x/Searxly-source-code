//
//  LocalIntelligenceManager.swift
//  Searxly
//
//  NEW FILE — Primary manager for all on-device Local AI (Apple Intelligence first).
//  Follows the exact singleton + @Observable @MainActor pattern of LocalSearxngManager.swift
//  and the extraction discipline used for BrowserState.
//
//  Phase 0 responsibilities (safe, no behavior change):
//  - Master enable (via UserDefaults initially; will migrate to AppData in Phase 0 wiring).
//  - Availability probe (real Apple check when framework present).
//  - Status surface for UI.
//  - No-op or guarded entry points for rewrite/synthesize/chat/rag so later phases can
//    fill them in without touching call sites.
//  - Explicit unload + resource observability hooks.
//  - All AI work is a no-op when !masterEnabled.
//
//  CRITICAL PRIVACY CONTRACT (enforced here):
//  - Zero network calls from this file or anything it calls (except explicit Ollama localhost
//    when the user has deliberately enabled the experimental fallback gate).
//  - RAG never runs unless explicitly allowed by the user for the specific sources.
//  - Every public method checks masterEnabled first.
//

import Foundation
import os
import SwiftUI
import Observation
import AppKit   // for NSPasteboard in diagnostics export

@Observable
@MainActor
final class LocalIntelligenceManager {
    static let shared = LocalIntelligenceManager()

    // MARK: - Observable State (UI can bind directly)

    private(set) var status: LocalAIStatus = .disabled
    private(set) var availability: IntelligenceAvailability = .unavailable("Not probed yet")
    private(set) var isGenerating = false
    private(set) var lastError: String?
    private(set) var recentActions: [AIAction] = []   // In-memory ring for this session (full log persisted lightly)

    /// Current preferences (source of truth for the session). Synced from persistence on load.
    /// The LocalAISettingsView (and only the settings surface + manager itself) mutates this directly.
    /// All other code should go through the manager's feature methods or isEnabled.
    var preferences = AIPreferences.default

    // Hardware constraints for low-memory machines (e.g. 8 GB unified memory).
    // Apple officially recommends 16 GB+ for a good Apple Intelligence experience.
    // On 8 GB the on-device model can sometimes load, but RAG + long context quickly causes
    // swapping and poor performance. We detect and protect the user automatically.
    var detectedPhysicalMemoryGB: Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int(Double(bytes) / (1024 * 1024 * 1024))
    }

    var isLowMemoryDevice: Bool {
        detectedPhysicalMemoryGB <= 8
    }

    /// High-performance device (e.g. M4 Pro/Max with 16 GB+ unified memory, or any 24 GB+).
    /// On these machines we unlock larger conversation history, slightly more aggressive RAG,
    /// longer idle keep-alive, and other rapidity enhancements so the on-device experience
    /// feels snappier instead of artificially throttled.
    var isHighPerformanceDevice: Bool {
        detectedPhysicalMemoryGB >= 16
    }

    // Internal
    private let masterKey = "LocalAI.MasterEnabled"
    private var currentProvider: IntelligenceProvider?
    private var idleUnloadTask: Task<Void, Never>?

    /// The active provider.
    /// Selection logic:
    /// - If experimentalFallbacksEnabled && useOllama → OllamaProvider (user chose via the chat model selector or settings)
    /// - Otherwise → AppleIntelligenceProvider (default, and the only option when the experimental gate is off)
    /// The chat sheet shows a model selector (On-device | Ollama). When the experimental toggle is off
    /// in Settings, the selector is visible but greyed/disabled (users can see the option but can't click it).
    ///
    /// IMPORTANT: selection is now live. Changing the experimental gate or the chat picker (or editing
    /// ollama model name while the gate+ollama are active) causes an immediate reselect so the next
    /// generate/rewrite/synthesis call uses the correct concrete provider. Stale instances are unloaded.
    var currentIntelligenceProvider: IntelligenceProvider {
        if currentProvider == nil {
            ensureProvider()
        }
        return currentProvider!
    }

    /// Cached on-device provider borrowed for cheap auxiliary jobs (see `auxiliaryProvider()`).
    /// Kept separate from `currentProvider` so it survives chat-backend switches.
    private var auxAppleProvider: (any IntelligenceProvider)?

    /// True only when the on-device Apple model genuinely probed as available.
    /// `availability` retains the real Apple probe result even when the cloud / Ollama gate
    /// forces `status = .ready`, so this is a reliable signal (unlike `status`).
    private var appleModelAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// Provider to use for cheap auxiliary jobs (query rewrite, follow-up suggestions, conversation
    /// titles). These never need the paid cloud 70B — running them on-device is faster, cheaper, and
    /// more private. Returns nil to signal "skip this optional job" when the chat is on the cloud and
    /// there's no free on-device model to borrow, so callers no-op instead of spending cloud tokens.
    func auxiliaryProvider() -> IntelligenceProvider? {
        // Apple or local Ollama: the active provider is already free/local — just use it.
        if !(currentIntelligenceProvider is CloudIntelligenceProvider) {
            return currentIntelligenceProvider
        }
        // Active chat is the paid cloud. Borrow the on-device Apple model if it's truly available.
        // `appleModelAvailable` can only be true on macOS 26+ (the probe returns .deviceNotSupported
        // below that), but the static #available guard is still required to construct the 26-only type.
        if appleModelAvailable, #available(macOS 26.0, *) {
            if auxAppleProvider == nil { auxAppleProvider = AppleIntelligenceProvider() }
            return auxAppleProvider
        }
        // No free model to borrow → don't bill the cloud for a nice-to-have.
        return nil
    }

    // RAG (Phase 4 + Core AI semantic upgrade + reranker High #2)
    private let ragEngine = RAGEngine()
    private var currentEmbeddingProvider: EmbeddingProvider?
    private var currentReranker: RerankerProvider?

    private init() {
        // Load full persisted AI preferences from AppData (encrypted if enabled).
        // This ensures chosen options (master, chat, tools, RAG, etc.) survive across app sessions/launches.
        let data = Persistence.load()
        self.preferences = data.aiPreferences

        // Per-session vs permanent Local AI chat conversations:
        // If the user has not enabled "save to disk", start with an empty list for this app run
        // (per-session). When the flag is true we keep the persisted list (including active ID).
        if !preferences.saveLocalAIChatHistory {
            preferences.localAIChatConversations = []
            preferences.activeLocalAIConversationID = nil
            // Do not persist the reset — if the user later turns the flag back on they can
            // decide whether old on-disk conversations should be revived.
        }

        // Apply hardware-based constraints (e.g. force low memory mode and disable heavy features on 8 GB machines).
        applyHardwareConstraints()

        // Legacy migration: if old UserDefaults master was set, apply it (one time).
        let savedMaster = UserDefaults.standard.bool(forKey: masterKey)
        if savedMaster && !preferences.masterEnabled {
            preferences.masterEnabled = true
            persistPreferences()
            UserDefaults.standard.removeObject(forKey: masterKey)
        }

        // Kick off a cheap availability probe (non-blocking).
        Task { await refreshAvailability() }
    }

    // MARK: - Public API — Master Control (used by Settings + everywhere)

    var isEnabled: Bool {
        // Release kill switch first: while the AI program is off, the manager reports itself
        // disabled everywhere regardless of the user's saved preference (which is preserved).
        get { AIFeatures.programEnabled && preferences.masterEnabled }
        set {
            guard newValue != preferences.masterEnabled else { return }
            preferences.masterEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: masterKey)

            if newValue {
                Task { await refreshAvailability() }
                // Warm the model proactively when the user enables the feature so first chat feels instant.
                // Note: warmUpIfNeeded() is intentionally synchronous — it spawns its own background Task
                // to perform a cheap one-shot generation. Awaiting it would be meaningless and triggers
                // the "no async operations" warning, so we call it directly (fire-and-forget).
                warmUpIfNeeded()
                logAction(.settingsChange, summary: "Local AI master enabled", usedModel: false)
            } else {
                Task { await self.unloadAll() }
                status = .disabled
                logAction(.settingsChange, summary: "Local AI master disabled", usedModel: false)
            }
        }
    }

    /// Call this on app launch or when user returns to Settings to get fresh status.
    func refreshAvailability() async {
        if !AIFeatures.programEnabled || !preferences.masterEnabled {
            status = .disabled
            return
        }

        status = .checking
        lastError = nil

        // Probe the primary (Apple) first. If the user has explicitly enabled the experimental
        // Ollama fallback gate, we still report Apple availability but will use the fallback
        // provider for actual work (see currentIntelligenceProvider getter).
        let avail: IntelligenceAvailability
        if #available(macOS 26.0, *) {
            avail = await AppleIntelligenceProvider.probeAvailability()
        } else {
            // On-device Apple Intelligence (FoundationModels) requires macOS 26+. Below that the
            // on-device path simply reports unavailable; the cloud / Ollama backends remain selectable.
            avail = .deviceNotSupported
        }
        availability = avail

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
            Log.ai.info("[LocalAI] availability probe result: \(String(describing: avail), privacy: .public)")
        }

        switch avail {
        case .available:
            status = .ready
            ensureProvider()
        case .appleIntelligenceNotEnabled, .deviceNotSupported, .modelNotReady, .unavailable:
            status = .unavailable(avail)
        }

        // When the user has explicitly turned on the experimental Ollama (or other) local LLM fallback,
        // we still want the feature UI (chat button, synthesis, etc.) to be available even if the
        // Apple Intelligence probe reported unavailable. The actual work will go through the Ollama
        // provider (which may itself fail gracefully if the localhost server isn't running).
        // This prevents the documented "enable experimental fallbacks" toggle from appearing to do nothing.
        if (preferences.experimentalFallbacksEnabled || preferences.searxlyAIEnabled) && status != .ready {
            status = .ready
            ensureProvider()
        }
    }

    /// Force a full unload of any loaded model/session (user action or low-memory policy).
    func unloadAll() async {
        status = .unloading
        await currentProvider?.unload()
        currentProvider = nil
        currentEmbeddingProvider?.unload()
        currentEmbeddingProvider = nil
        currentReranker?.unload()
        currentReranker = nil
        isGenerating = false
        cancelIdleUnload()

        if preferences.masterEnabled {
            status = .ready
        } else {
            status = .disabled
        }
        logAction(.modelUnload, summary: "On-device models unloaded", usedModel: false)
    }

    // MARK: - Feature Entry Points (Phase 0: safe no-ops or guarded)

    /// Returns a (possibly rewritten) query. When disabled or unavailable, returns the original unchanged.
    /// Real on-device rewrite (Phase 1) via Apple Intelligence when the user has explicitly enabled the feature.
    func rewriteIfEnabled(original: String) async -> String {
        guard preferences.masterEnabled && preferences.rewriteEnabled else { return original }
        guard canUseFeatures else { return original }

        isGenerating = true
        defer { isGenerating = false }

        ensureProvider()
        // Query rewrite is a cheap throwaway job — never bill the cloud 70B for it. Borrow the
        // on-device model when the chat is on cloud; skip entirely if no free model is available.
        guard let provider = auxiliaryProvider() else { return original }

        let improved = await QueryRewriter.rewrite(original, using: provider)

        if improved != original {
            logAction(.queryRewrite, summary: "Rewrote '\(original)' → '\(improved)'", detail: "original: \(original)", usedModel: true)
        } else {
            logAction(.queryRewrite, summary: "No rewrite improvement for '\(original)'", usedModel: true)
        }
        return improved
    }

    /// Synthesize the current search results. Returns nil when disabled.
    func synthesizeIfEnabled(query: String, results: [SearXNGResult]) async -> AISummary? {
        guard preferences.masterEnabled && preferences.synthesisEnabled else { return nil }
        guard !results.isEmpty else { return nil }

        // Ensure provider — honor the user's experimental fallback toggle (do not hardcode Apple).
        ensureProvider()
        guard let provider = currentProvider else { return nil }

        isGenerating = true
        defer { isGenerating = false }

        let summary = await ResultSynthesizer.synthesize(query: query, results: results, using: provider)

        if let summary {
            logAction(.synthesis, summary: "Synthesized '\(query)' from \(results.count) snippets", detail: "\(summary.citations.count) citations", usedModel: true)
            // Keep the synthesis in BrowserState (caller sets currentAISynthesis)
        } else {
            logAction(.synthesis, summary: "Synthesis for '\(query)' produced no usable result", usedModel: true)
        }

        return summary
    }

    /// Open / continue a contextual chat.
    func startOrContinueChat() {
        guard preferences.masterEnabled && preferences.chatEnabled else { return }
        logAction(.chatTurn, summary: "Chat session started", usedModel: false)
    }

    /// Rebuild the RAG index from the provided (already persisted) user data.
    /// Should be called when RAG is toggled on, after major history/bookmark changes,
    /// or explicitly from settings.
    ///
    /// On macOS 27+ with semanticRAGEnabled + a Core AI embedding model path, this will also
    /// compute on-device embeddings for semantic retrieval (via CoreAIEmbeddingProvider).
    func rebuildRAGIndex(history: [HistoryItem], bookmarks: [BookmarkItem]) {
        guard preferences.masterEnabled && preferences.ragEnabled else { return }

        // Create (or reuse) the embedding provider for this rebuild if semantic is on.
        if preferences.semanticRAGEnabled {
            if currentEmbeddingProvider == nil {
                currentEmbeddingProvider = CoreAIEmbeddingProvider.make(preferences: preferences)
            }
        } else {
            currentEmbeddingProvider?.unload()
            currentEmbeddingProvider = nil
        }

        // Reranker (High #2)
        if preferences.rerankerEnabled {
            if currentReranker == nil {
                currentReranker = CoreAIRerankerProvider.make(preferences: preferences)
            }
        } else {
            currentReranker?.unload()
            currentReranker = nil
        }

        ragEngine.rebuildIndex(from: history, bookmarks: bookmarks, preferences: preferences, embeddingProvider: currentEmbeddingProvider, reranker: currentReranker)
        let mode = [
            (currentEmbeddingProvider != nil && preferences.semanticRAGEnabled) ? "semantic" : nil,
            (currentReranker != nil && preferences.rerankerEnabled) ? "reranked" : nil
        ].compactMap { $0 }.joined(separator: "+")
        let displayMode = mode.isEmpty ? "keyword" : "Core AI (\(mode))"
        logAction(.ragRetrieval, summary: "RAG index rebuilt (\(displayMode))", detail: "\(ragEngine.count) items", usedModel: false)
    }

    /// Retrieve relevant local items for RAG. Empty when disabled or no sources allowed.
    /// FIX (P5): if the in-memory index is empty but RAG is enabled, auto-rebuild from the
    /// persisted AppData (history + bookmarks). This makes RAG "just work" even if the user
    /// toggled it on outside of openLocalAIChat, or after a clear/relaunch, without requiring
    /// an explicit "Rebuild" tap or re-opening the chat.
    func retrieveRAGIfEnabled(query: String) async -> [RAGItem] {
        guard preferences.masterEnabled && preferences.ragEnabled else { return [] }
        if !preferences.ragIncludeHistory && !preferences.ragIncludeBookmarks { return [] }

        if ragEngine.count == 0 {
            let data = Persistence.load()
            // Re-create embedding + reranker for auto-rebuild path if requested.
            if preferences.semanticRAGEnabled && currentEmbeddingProvider == nil {
                currentEmbeddingProvider = CoreAIEmbeddingProvider.make(preferences: preferences)
            }
            if preferences.rerankerEnabled && currentReranker == nil {
                currentReranker = CoreAIRerankerProvider.make(preferences: preferences)
            }
            ragEngine.rebuildIndex(from: data.history, bookmarks: data.bookmarks, preferences: preferences, embeddingProvider: currentEmbeddingProvider, reranker: currentReranker)
            if ragEngine.count > 0 {
                let m = [
                    (currentEmbeddingProvider != nil && preferences.semanticRAGEnabled) ? "semantic" : nil,
                    (currentReranker != nil && preferences.rerankerEnabled) ? "reranked" : nil
                ].compactMap { $0 }.joined(separator: "+")
                let mode = m.isEmpty ? "keyword" : "Core AI (\(m))"
                logAction(.ragRetrieval, summary: "RAG index auto-rebuilt on first retrieve (\(mode))", detail: "\(ragEngine.count) items", usedModel: false)
            }
        }

        // High-performance devices (M4 Pro 24 GB+, etc.) get more RAG items for richer personal context
        // without hurting speed (more unified memory + fast silicon).
        let k = isHighPerformanceDevice ? min(18, preferences.ragMaxItems) : min(10, preferences.ragMaxItems)
        let items = await ragEngine.retrieve(query: query, k: k)
        if !items.isEmpty {
            logAction(.ragRetrieval, summary: "RAG retrieved \(items.count) items for query", detail: query, usedModel: false)
        }
        return items
    }

    var ragItemCount: Int {
        preferences.masterEnabled && preferences.ragEnabled ? ragEngine.count : 0
    }

    func clearRAGIndex() {
        currentEmbeddingProvider?.unload()
        currentEmbeddingProvider = nil
        currentReranker?.unload()
        currentReranker = nil
        ragEngine.clear()
        logAction(.ragRetrieval, summary: "RAG index cleared", usedModel: false)
    }

    /// For the audit sheet in settings. Returns current indexed items if RAG is active.
    func getCurrentRAGItems() -> [RAGItem] {
        guard preferences.masterEnabled && preferences.ragEnabled else { return [] }
        // Note: if index not yet built for this session, this may be empty until a chat or explicit rebuild.
        return ragEngine.allItems()
    }

    // MARK: - Resource & Transparency Helpers

    func logAction(_ type: AIActionType, summary: String, detail: String? = nil, usedModel: Bool = false) {
        let action = AIAction(type: type, summary: summary, detail: detail, usedModel: usedModel)
        recentActions.insert(action, at: 0)
        if recentActions.count > 100 { recentActions.removeLast() }

        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
            Log.ai.info("[LocalAI] \(type.rawValue): \(summary)")
        }
    }

    func clearRecentActions() {
        recentActions.removeAll()
    }

    /// Direct one-shot generation using the on-device provider (Apple Intelligence or Ollama fallback).
    /// Useful for built-in features like password suggestions in forms, without opening the full chat sheet.
    /// Returns the generated text or nil on failure.
    func generateOneShot(prompt: String, instructions: String? = "You are a helpful assistant. Respond concisely.") async -> String? {
        guard preferences.masterEnabled else { return nil }
        do {
            if currentProvider == nil {
                ensureProvider()
            }
            guard let provider = currentProvider else { return nil }
            let result = try await provider.generate(prompt: prompt, instructions: instructions)
            logAction(.synthesis, summary: "One-shot generation for built-in feature", detail: prompt.prefix(50) + "...", usedModel: true)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.ai.error("[LocalAI] one-shot generate failed: \(error)")
            return nil
        }
    }

    /// Persist the current AI preferences to disk (AppData.json, respecting encryption if enabled).
    /// Call this after any direct mutation of `preferences` (e.g. from settings toggles or quick-enables)
    /// so that chosen options survive across app sessions and launches.
    func persistPreferences() {
        var data = Persistence.load()
        data.aiPreferences = preferences
        Persistence.save(data)
    }

    /// Called by Performance / low-memory paths or background.
    func considerIdleUnload() {
        guard preferences.masterEnabled else { return }
        cancelIdleUnload()

        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            // Performance: on high-RAM devices (M4 Pro 24 GB etc.) we keep the model resident longer
            // by default so re-opening the chat feels instant. User can still lower the pref.
            let baseIdle = self.preferences.idleUnloadSeconds
            let effectiveIdle = self.isHighPerformanceDevice ? max(baseIdle, 600) : baseIdle
            try? await Task.sleep(for: .seconds(Int(effectiveIdle)))
            if !Task.isCancelled {
                await self.unloadAll()
            }
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    /// Applies automatic restrictions on low-memory devices (currently 8 GB or less).
    /// Forces lowMemoryMode on and disables RAG (including semantic + reranker) to avoid
    /// swapping, excessive memory pressure, and degraded experience.
    /// This is called on init and can be re-applied if needed.
    private func applyHardwareConstraints() {
        guard isLowMemoryDevice else { return }

        var changed = false

        if !preferences.lowMemoryMode {
            preferences.lowMemoryMode = true
            changed = true
        }

        if preferences.ragEnabled {
            preferences.ragEnabled = false
            changed = true
        }

        // Also turn off the more expensive RAG sub-features even if the master was already off.
        if preferences.semanticRAGEnabled {
            preferences.semanticRAGEnabled = false
            changed = true
        }
        if preferences.rerankerEnabled {
            preferences.rerankerEnabled = false
            changed = true
        }

        if changed {
            persistPreferences()
            // Make sure any previously built in-memory index is dropped immediately.
            clearRAGIndex()
        }
    }

    // MARK: - Internal

    private func ensureProvider() {
        // Three possible backends. Searxly AI (cloud) takes precedence when selected, then the
        // experimental Ollama fallback, otherwise the default on-device Apple Intelligence.
        enum Backend { case apple, ollama, searxly }

        let desired: Backend = {
            if preferences.searxlyAIEnabled && preferences.useSearxlyAI { return .searxly }
            if preferences.experimentalFallbacksEnabled && preferences.useOllama { return .ollama }
            return .apple
        }()

        let current: Backend = {
            if currentProvider is CloudIntelligenceProvider { return .searxly }
            if currentProvider is OllamaProvider { return .ollama }
            return .apple
        }()

        // Create if missing, OR replace when the live instance type no longer matches the desired choice,
        // so flipping the chat model picker / a settings toggle immediately routes to the right provider.
        let needsRecreate = currentProvider == nil || current != desired

        if needsRecreate {
            // Unload whatever was there (best effort; Apple sessions have state, the HTTP providers are stateless).
            if let old = currentProvider {
                Task { await old.unload() }
            }
            currentProvider = nil

            switch desired {
            case .searxly:
                // Cloud config is operator-only (SearxlyAICloud), never user-editable in the product UI.
                currentProvider = CloudIntelligenceProvider(
                    modelName: SearxlyAICloud.model,
                    baseURL: SearxlyAICloud.baseURL,
                    apiKey: SearxlyAICloud.apiKey
                )
                logAction(.modelLoad, summary: "Searxly AI (cloud) provider initialized", usedModel: false)
            case .ollama:
                let url = URL(string: preferences.ollamaBaseURL) ?? URL(string: "http://127.0.0.1:11434")!
                currentProvider = OllamaProvider(modelName: preferences.ollamaModelName, baseURL: url)
                logAction(.modelLoad, summary: "Ollama provider initialized (via chat model selector or prefs)", usedModel: false)
            case .apple:
                if #available(macOS 26.0, *) {
                    currentProvider = AppleIntelligenceProvider()
                    logAction(.modelLoad, summary: "Apple Intelligence provider initialized", usedModel: false)
                } else {
                    // FoundationModels is macOS 26+. Use the inert stand-in so the getter never
                    // force-unwraps nil; on-device AI is reported unavailable (.deviceNotSupported) and
                    // the UI disables it. No network is touched. Users on older macOS can still pick a
                    // cloud or Ollama backend, which routes through the cases above.
                    currentProvider = UnavailableIntelligenceProvider()
                    logAction(.modelLoad, summary: "On-device AI unavailable (requires macOS 26+)", usedModel: false)
                }
            }
        }
    }

    /// Force a provider reselection based on the *current* values of experimentalFallbacksEnabled + useOllama.
    /// Unloads any existing provider, nils the slot, then touches the getter so ensureProvider() builds
    /// the correct concrete type (Apple vs Ollama) for the next operation.
    /// Call this after the user flips the experimental gate or uses the chat sheet's model picker.
    func reselectProvider() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.currentProvider?.unload()
            self.currentProvider = nil
            // Touching the getter forces ensureProvider() which now does the full wantsOllama vs current-type check.
            _ = self.currentIntelligenceProvider
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] reselectProvider() completed — active provider is now \(self.currentIntelligenceProvider.capabilities.name)")
            }
        }
    }

    /// When the user edits the Ollama model name or baseURL in settings while the experimental
    /// gate + Ollama choice are active, push the new values into the live OllamaProvider instance
    /// (if one exists). This makes the very next message in an open chat use the newly chosen model/endpoint
    /// without requiring a full class swap or chat close/reopen.
    /// Safe no-op when not on the Ollama path.
    func applyLiveOllamaConfig() {
        if let ollama = currentProvider as? OllamaProvider {
            ollama.modelName = preferences.ollamaModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: preferences.ollamaBaseURL) {
                ollama.baseURL = u
            }
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] applyLiveOllamaConfig() — live Ollama now model='\(ollama.modelName)' url=\(ollama.baseURL)")
            }
        }
    }

    /// Push edited Searxly AI (cloud) settings into the live provider instance (if active) so the next
    /// message uses the new model / URL / key without reopening the chat. Safe no-op otherwise.
    func applyLiveSearxlyAIConfig() {
        if let cloud = currentProvider as? CloudIntelligenceProvider {
            cloud.modelName = preferences.searxlyAIModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: preferences.searxlyAIBaseURL) {
                cloud.baseURL = u
            }
            cloud.apiKey = preferences.searxlyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] applyLiveSearxlyAIConfig() — live Searxly AI now model='\(cloud.modelName)' url=\(cloud.baseURL)")
            }
        }
    }

    // MARK: - Local AI Chat conversations (list of previous + current active one)
    // Supports the "Conversations" button so users can browse and switch between past chats.
    // The active one is the one loaded in the chat sheet. Model switch or "new" archives the
    // previous (if it has content) and creates/activates a fresh one.
    // The saveLocalAIChatHistory flag controls whether the list (and active ID) is written to disk.

    /// Ensures there is an active conversation. If none, creates a new empty one and activates it.
    /// Returns the active SavedConversation (or creates one).
    @discardableResult
    func ensureActiveLocalAIConversation(backendDescription: String = "Apple Intelligence") -> SavedConversation {
        if let id = preferences.activeLocalAIConversationID,
           let existing = preferences.localAIChatConversations.first(where: { $0.id == id }) {
            return existing
        }

        // Create a fresh one
        let newConv = SavedConversation(
            title: "New conversation",
            backend: backendDescription
        )
        preferences.localAIChatConversations.append(newConv)
        preferences.activeLocalAIConversationID = newConv.id

        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
        return newConv
    }

    /// Start a new conversation (used by model picker switch and explicit New button).
    /// If the current active has messages, it stays in the history list (archived).
    /// Creates and activates a new empty SavedConversation with the given backend snapshot.
    /// Also unloads the provider (the next use will recreate for the new backend).
    func startNewLocalAIChat(backendDescription: String) {
        // If there is an active with content, it is already in the list and will remain there as previous.
        // Just create a new one and activate it.
        let newConv = SavedConversation(
            title: "New conversation",
            backend: backendDescription
        )
        preferences.localAIChatConversations.append(newConv)
        preferences.activeLocalAIConversationID = newConv.id

        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }

        // Unload so next generation uses the (newly selected) backend with a clean state.
        Task { [weak self] in
            await self?.currentProvider?.unload()
            if let self { self.currentProvider = nil }
        }
    }

    /// Update the active conversation's messages (called from the chat sheet after changes).
    /// Also refreshes updatedAt and auto-generates a title from the first user message if the title is still the default.
    /// Persists only if the save flag is on.
    func updateActiveLocalAIConversation(messages: [ChatMessage], backendDescription: String? = nil) {
        guard let id = preferences.activeLocalAIConversationID,
              let idx = preferences.localAIChatConversations.firstIndex(where: { $0.id == id }) else {
            return
        }

        var conv = preferences.localAIChatConversations[idx]
        conv.messages = messages
        conv.updatedAt = Date()
        if let bd = backendDescription {
            conv.backend = bd
        }

        // Auto title from first user message if still default
        if conv.title == "New conversation" || conv.title.isEmpty {
            if let firstUser = messages.first(where: { $0.role == .user }) {
                let preview = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
                conv.title = String(preview.prefix(60)) + (preview.count > 60 ? "..." : "")
                if conv.title.isEmpty { conv.title = "New conversation" }
            }
        }

        preferences.localAIChatConversations[idx] = conv

        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
    }

    /// Get the active conversation (creates one if needed).
    func getActiveLocalAIConversation(backendDescription: String = "Apple Intelligence") -> SavedConversation {
        return ensureActiveLocalAIConversation(backendDescription: backendDescription)
    }

    /// Clear / delete the active conversation's content (keeps the entry or removes?).
    /// For the "Clear chat" action we empty the active one (it stays in history as a short entry).
    /// For full clear we can also remove it from the list.
    func clearCurrentChatTranscript() {
        guard let id = preferences.activeLocalAIConversationID,
              let idx = preferences.localAIChatConversations.firstIndex(where: { $0.id == id }) else {
            preferences.localAIChatConversations = []
            preferences.activeLocalAIConversationID = nil
            if preferences.saveLocalAIChatHistory { persistPreferences() }
            return
        }

        // Empty the active one but keep the entry in history (user can still see it had a chat)
        var conv = preferences.localAIChatConversations[idx]
        conv.messages = []
        conv.title = "Cleared conversation"
        conv.updatedAt = Date()
        preferences.localAIChatConversations[idx] = conv

        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
    }

    /// Load a specific conversation as the active one (for the "Conversations" history button).
    /// Returns true if successful.
    @discardableResult
    func loadLocalAIConversation(id: UUID) -> Bool {
        guard preferences.localAIChatConversations.contains(where: { $0.id == id }) else { return false }
        preferences.activeLocalAIConversationID = id
        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
        return true
    }

    /// Delete a conversation from the list (used from the history UI).
    func deleteLocalAIConversation(id: UUID) {
        preferences.localAIChatConversations.removeAll { $0.id == id }
        if preferences.activeLocalAIConversationID == id {
            preferences.activeLocalAIConversationID = preferences.localAIChatConversations.last?.id
        }
        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
    }

    /// Delete all conversations (for the big clear action when permanent history is on).
    func clearAllLocalAIConversations() {
        preferences.localAIChatConversations = []
        preferences.activeLocalAIConversationID = nil
        if preferences.saveLocalAIChatHistory {
            persistPreferences()
        }
    }

    // MARK: - Diagnostics (for user reports + Xcode console debugging)

    /// Builds a comprehensive, privacy-safe diagnostics report for Local AI issues.
    /// User can copy this and send it (along with Xcode console output when verbose logging is on).
    func localAIDiagnosticsReport() -> String {
        var lines: [String] = []
        let now = ISO8601DateFormatter().string(from: Date())

        lines.append("=== Searxly Local AI Diagnostics ===")
        lines.append("Generated: \(now)")
        lines.append("Prompt version: \(AIPromptLibrary.promptVersion)")
        lines.append("Rules version: \(AIRules.rulesVersion)")
        lines.append("")

        // Status & Availability
        lines.append("--- Status ---")
        lines.append("Master enabled: \(preferences.masterEnabled)")
        lines.append("canUseFeatures: \(canUseFeatures)")
        lines.append("Status: \(statusDescription)")
        lines.append("Availability: \(availability)")
        lines.append("isGenerating: \(isGenerating)")
        if let err = lastError { lines.append("Last error: \(err)") }
        lines.append("")

        // Hardware / memory constraints
        lines.append("--- Hardware ---")
        lines.append("Detected physical memory: \(detectedPhysicalMemoryGB) GB")
        lines.append("Low memory device (protective mode): \(isLowMemoryDevice)")
        lines.append("High performance device (larger context + faster feel + more RAG): \(isHighPerformanceDevice)")
        lines.append("Effective RAG k this session: up to \(isHighPerformanceDevice ? min(18, preferences.ragMaxItems) : min(10, preferences.ragMaxItems)) (high-perf devices get more)")
        lines.append("")

        // Preferences snapshot (key ones for AI behavior)
        lines.append("--- Preferences ---")
        lines.append("chatEnabled: \(preferences.chatEnabled)")
        lines.append("toolsEnabled: \(preferences.toolsEnabled)")
        lines.append("ragEnabled: \(preferences.ragEnabled)")
        lines.append("ragIncludeHistory: \(preferences.ragIncludeHistory)")
        lines.append("ragIncludeBookmarks: \(preferences.ragIncludeBookmarks)")
        lines.append("ragMaxItems: \(preferences.ragMaxItems)")
        lines.append("semanticRAGEnabled: \(preferences.semanticRAGEnabled)")
        lines.append("rerankerEnabled: \(preferences.rerankerEnabled)")
        lines.append("rewriteEnabled: \(preferences.rewriteEnabled)")
        lines.append("synthesisEnabled: \(preferences.synthesisEnabled)")
        lines.append("experimentalFallbacksEnabled: \(preferences.experimentalFallbacksEnabled)")
        lines.append("useOllama (chat model selector): \(preferences.useOllama)")
        lines.append("ollamaModelName: \(preferences.ollamaModelName)")
        lines.append("ollamaBaseURL: \(preferences.ollamaBaseURL)")
        lines.append("saveLocalAIChatHistory: \(preferences.saveLocalAIChatHistory)")
        lines.append("localAIChatConversations count: \(preferences.localAIChatConversations.count)")
        lines.append("active conversation ID: \(preferences.activeLocalAIConversationID?.uuidString ?? "none")")
        lines.append("lowMemoryMode: \(preferences.lowMemoryMode)")
        if let embPath = preferences.coreAIEmbeddingModelPath { lines.append("coreAIEmbeddingModelPath: \(embPath)") }
        if let rerankPath = preferences.coreAIRerankerModelPath { lines.append("coreAIRerankerModelPath: \(rerankPath)") }
        lines.append("")

        // RAG state
        lines.append("--- RAG ---")
        lines.append("Current RAG item count: \(ragItemCount)")
        lines.append("Semantic RAG enabled + provider: \(preferences.semanticRAGEnabled && currentEmbeddingProvider != nil)")
        lines.append("Reranker enabled + provider: \(preferences.rerankerEnabled && currentReranker != nil)")
        lines.append("Embedding provider loaded: \(currentEmbeddingProvider != nil)")
        lines.append("Reranker provider loaded: \(currentReranker != nil)")
        lines.append("")

        // Provider
        lines.append("--- Provider ---")
        let prov = currentIntelligenceProvider
        lines.append("Current provider: \(prov.capabilities.name)")
        lines.append("Supports streaming: \(prov.capabilities.supportsStreaming)")
        lines.append("Supports native tools: \(prov.capabilities.supportsNativeTools)")
        lines.append("Selected via experimental + useOllama: \(preferences.experimentalFallbacksEnabled && preferences.useOllama)")
        lines.append("")

        // Recent activity
        lines.append("--- Recent Actions (last \(min(30, recentActions.count))) ---")
        let recentForReport = Array(recentActions.prefix(30))
        lines.append(AIActivityLog.exportAsText(recentForReport))
        lines.append("")

        // Instructions for reporter
        lines.append("--- How to get more info for debugging ---")
        lines.append("1. In Developer Settings (if available), enable 'Verbose AI Logging'.")
        lines.append("2. Reproduce the issue (e.g. send the prompt in Local AI Chat).")
        lines.append("3. In Xcode, filter console for '[LocalAI]' and paste the relevant lines here.")
        lines.append("4. Also include this full diagnostics report.")
        lines.append("5. Note: exact user prompts / full chat history are not included here for privacy (only summaries and counts).")
        lines.append("")
        lines.append("If the app crashed, please also include the crash report from Console.app or Xcode.")
        lines.append("=== End of Local AI Diagnostics ===")

        return lines.joined(separator: "\n")
    }

    /// Copies a full diagnostics bundle to the pasteboard. Safe and convenient for reporting bugs.
    func copyDiagnosticsToPasteboard() {
        let report = localAIDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        logAction(.settingsChange, summary: "Full Local AI diagnostics copied to clipboard", usedModel: false)

        // Also append a console note if verbose
        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
            Log.ai.info("[LocalAI] Full diagnostics report copied to pasteboard.")
        }
    }
}

// MARK: - Convenience for UI (no extra imports needed in views)

extension LocalIntelligenceManager {
    /// Convenience for UI buttons.
    func copyLocalAIDiagnostics() {
        copyDiagnosticsToPasteboard()
    }

    var statusDescription: String {
        switch status {
        case .disabled: return "Off"
        case .checking: return "Checking..."
        case .ready:    return "Ready (on-device)"
        case .generating: return "Generating locally..."
        case .unloading: return "Unloading"
        case .unavailable(let a): return IntelligenceAvailabilityChecker.guidance(for: a)
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var canUseFeatures: Bool {
        guard AIFeatures.programEnabled, preferences.masterEnabled else { return false }
        if status == .ready || status == .generating { return true }
        // User has explicitly enabled the experimental local LLM fallback (Ollama etc.).
        // Treat the Local AI features as usable for the UI (chat input, synthesis button, etc.)
        // so the user can type and send. The actual provider (see currentIntelligenceProvider + ensureProvider)
        // will be the fallback one; runtime errors (e.g. Ollama server not running) are reported with clear messages.
        if preferences.experimentalFallbacksEnabled || preferences.searxlyAIEnabled { return true }
        return false
    }

    var toolsEnabled: Bool {
        preferences.masterEnabled && preferences.toolsEnabled
    }

    /// Whether an individual tool (by id from AIToolCatalog / CloudTool.name) is switched on.
    /// This is the per-tool layer; the master `toolsEnabled` switch still gates all tool use.
    func isToolEnabled(_ id: String) -> Bool {
        !preferences.disabledToolIDs.contains(id)
    }

    /// Turn a single tool on/off and persist immediately (synchronous persist — never via a deferred Task,
    /// matching the toggle-persistence guidance so a quick quit can't lose the change).
    func setToolEnabled(_ id: String, _ enabled: Bool) {
        if enabled {
            preferences.disabledToolIDs.remove(id)
        } else {
            preferences.disabledToolIDs.insert(id)
        }
        persistPreferences()
        logAction(.settingsChange, summary: "Tool \(enabled ? "enabled" : "disabled"): \(id)")
    }

    /// Called when the user toggles the experimental fallback pref so that chat/synthesis/etc.
    /// become immediately usable in the UI without waiting for the async Apple probe in refresh.
    /// Forces a true reselection of the provider (Apple vs Ollama) so the live currentProvider
    /// matches the new gate value even if a previous instance of the other type was resident.
    func noteExperimentalFallbackToggled() {
        guard preferences.masterEnabled else { return }
        if status != .ready && status != .generating {
            status = .ready
        }
        // Always reselect when the gate changes (even if turning it off). The reselect path
        // will look at the *current* experimental+useOllama flags and build the right concrete provider.
        reselectProvider()
    }

    /// Same as noteExperimentalFallbackToggled, for the Searxly AI (cloud) opt-in toggle.
    func noteSearxlyAIToggled() {
        guard preferences.masterEnabled else { return }
        if status != .ready && status != .generating {
            status = .ready
        }
        reselectProvider()
    }

    /// Eager warm-up for the on-device model (performance enhancement for high-RAM machines
    /// like M4 Pro 24 GB). Called on chat open (and on master enable) so the first real user message
    /// doesn't pay the full model load + first-token latency. Does a trivial one-shot generation
    /// in the background that is discarded. Safe and cheap.
    func warmUpIfNeeded() {
        guard preferences.masterEnabled && canUseFeatures else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.generateOneShot(
                prompt: "Hi",
                instructions: "Respond with a single short friendly word."
            )
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseAILogging {
                Log.ai.info("[LocalAI] Warm-up generation completed (background)")
            }
        }
    }
}