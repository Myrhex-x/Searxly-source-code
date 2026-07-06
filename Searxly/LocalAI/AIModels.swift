//
//  AIModels.swift
//  Searxly
//
//  NEW FILE (Phase 0 scaffolding).
//  Pure data models for on-device Local AI features.
//  All types Codable where persisted so they flow through the existing
//  EncryptedDataStore + AppData path (added in Phase 0 wiring).
//  Created to keep AI concerns isolated in LocalAI/ and prevent pollution
//  of core Models.swift or BrowserState.
//

import Foundation

// MARK: - Master Preferences (persisted, encrypted when user has encryption on)

struct AIPreferences: Codable, Equatable {
    /// Master kill switch. All AI features are inert when false (default).
    /// This is the single source of truth the UI and managers consult first.
    var masterEnabled: Bool = false

    // Granular feature flags (only honored when masterEnabled == true)
    var rewriteEnabled: Bool = false
    var synthesisEnabled: Bool = false
    var chatEnabled: Bool = false
    var ragEnabled: Bool = false   // RAG is further gated by source toggles below

    // RAG scope (only relevant when ragEnabled)
    var ragIncludeHistory: Bool = true
    var ragIncludeBookmarks: Bool = true
    /// Consider items newer than this date (nil = all time). UI typically offers presets.
    var ragRecencyCutoff: Date? = nil
    /// Soft cap on items considered for retrieval (keeps context small).
    var ragMaxItems: Int = 150

    // Resource / experience
    var lowMemoryMode: Bool = false
    /// Idle seconds after last AI use before manager may unload sessions (best effort).
    var idleUnloadSeconds: TimeInterval = 300

    /// Opt-in: Allow the on-device model to use tools (e.g. web search via *your* private SearXNG instances).
    /// This is deliberately separate from the chat toggle.
    /// When enabled, the AI may request to use tools during chat. Tool use is **always confirmed by you**
    /// in a clear UI and is logged in AI Activity. Tools only ever route through your configured private/local
    /// SearXNG instances — never public ones, never cloud.
    var toolsEnabled: Bool = false

    /// Per-tool opt-out set. Holds the ids (matching AIToolCatalog / CloudTool.name) of tools the user
    /// has switched OFF. Default empty = every tool is on, so newly shipped tools are opt-out, not opt-in.
    /// Only meaningful when `toolsEnabled` is true (the master switch still gates all tool use).
    var disabledToolIDs: Set<String> = []

    // Phase 5: Experimental local fallbacks (Ollama etc.). Off by default, clearly labeled.
    var experimentalFallbacksEnabled: Bool = false
    var ollamaModelName: String = "llama3.2"
    /// Configurable endpoint for the user's local Ollama (default = the standard localhost port
    /// used by the official Ollama.app the user downloaded). Changing this is advanced; the UI
    /// surfaces a strong privacy warning because any non-localhost value means prompts + RAG +
    /// attached files would leave the Mac.
    var ollamaBaseURL: String = "http://127.0.0.1:11434"

    /// When experimentalFallbacksEnabled is true, this lets the user choose Ollama vs the on-device Apple model
    /// from within the Local AI Chat (via a model selector). If experimentalFallbacksEnabled is false,
    /// the selector is visible but greyed out / disabled (only On-device is usable).
    var useOllama: Bool = false

    // MARK: - Searxly AI (cloud) — opt-in, OpenAI-compatible endpoint.
    // Mirrors the Ollama fields. The default base URL points at the user's LOCAL Ollama
    // OpenAI-compatible endpoint, so Searxly AI stays on-device until the user switches the URL
    // to their own hosted Searxly AI server / gateway. apiKey is an optional Bearer token.
    var searxlyAIEnabled: Bool = false
    var useSearxlyAI: Bool = false
    var searxlyAIModelName: String = "searxly-ai"
    var searxlyAIBaseURL: String = "http://127.0.0.1:11434/v1"
    var searxlyAIAPIKey: String = ""

    // Local AI Chat conversations history.
    // When saveLocalAIChatHistory is false (default), conversations live only in-memory for the
    // current app run ("per-session"). When true, the list is persisted via persistPreferences()
    // (encrypted if the user has at-rest encryption on) so previous conversations survive restarts.
    // The active conversation is the one currently loaded in the chat sheet.
    // A "Conversations" button in the chat sheet lets the user browse and switch between them.
    var saveLocalAIChatHistory: Bool = false
    var localAIChatConversations: [SavedConversation] = []
    var activeLocalAIConversationID: UUID? = nil

    // WWDC26 / macOS 27+: Core AI powered semantic RAG (embeddings for history + bookmarks).
    // When enabled (and a valid .aimodel path is supplied), RAG retrieval uses cosine similarity
    // over on-device embeddings instead of (or in addition to) keyword overlap. All computation
    // stays local via CoreAIRuntime / CoreAIAsset. Falls back gracefully to keyword if unavailable.
    var semanticRAGEnabled: Bool = false
    /// Absolute or tilde-expanded path to a Core AI exported embedding model (.aimodel or resource dir).
    /// Example: "~/Models/minilm-embed.aimodel" or "/Users/you/.../exported-embedding.aimodel"
    /// Obtain by using apple/coreai-models export recipes + coreai-torch (see LOCAL_AI_IMPLEMENTATION_NOTES.md).
    var coreAIEmbeddingModelPath: String? = nil

    // High priority follow-on: Core AI reranker (second-stage precision after first retrieval).
    // When enabled + semantic, after initial top-M recall we score query+doc pairs with a small
    // on-device reranker model and take the final top-k. Same user-supplied .aimodel model as embeddings.
    var rerankerEnabled: Bool = false
    var coreAIRerankerModelPath: String? = nil

    init() {
        masterEnabled = false
        rewriteEnabled = false
        synthesisEnabled = false
        chatEnabled = false
        ragEnabled = false
        ragIncludeHistory = true
        ragIncludeBookmarks = true
        ragRecencyCutoff = nil
        ragMaxItems = 150
        lowMemoryMode = false
        idleUnloadSeconds = 300
        toolsEnabled = false
        disabledToolIDs = []
        experimentalFallbacksEnabled = false
        ollamaModelName = "llama3.2"
        ollamaBaseURL = "http://127.0.0.1:11434"
        useOllama = false
        searxlyAIEnabled = false
        useSearxlyAI = false
        searxlyAIModelName = "searxly-ai"
        searxlyAIBaseURL = "http://127.0.0.1:11434/v1"
        searxlyAIAPIKey = ""
        saveLocalAIChatHistory = false
        localAIChatConversations = []
        activeLocalAIConversationID = nil
        semanticRAGEnabled = false
        coreAIEmbeddingModelPath = nil
        rerankerEnabled = false
        coreAIRerankerModelPath = nil
    }

    // Memberwise initializer (for convenience and to support things like AIPreferences(toolsEnabled: true))
    init(
        masterEnabled: Bool = false,
        rewriteEnabled: Bool = false,
        synthesisEnabled: Bool = false,
        chatEnabled: Bool = false,
        ragEnabled: Bool = false,
        ragIncludeHistory: Bool = true,
        ragIncludeBookmarks: Bool = true,
        ragRecencyCutoff: Date? = nil,
        ragMaxItems: Int = 150,
        lowMemoryMode: Bool = false,
        idleUnloadSeconds: TimeInterval = 300,   // manager may use longer effective value on high-perf hardware (see LocalIntelligenceManager)
        toolsEnabled: Bool = false,
        disabledToolIDs: Set<String> = [],
        experimentalFallbacksEnabled: Bool = false,
        ollamaModelName: String = "llama3.2",
        ollamaBaseURL: String = "http://127.0.0.1:11434",
        useOllama: Bool = false,
        searxlyAIEnabled: Bool = false,
        useSearxlyAI: Bool = false,
        searxlyAIModelName: String = "searxly-ai",
        searxlyAIBaseURL: String = "http://127.0.0.1:11434/v1",
        searxlyAIAPIKey: String = "",
        saveLocalAIChatHistory: Bool = false,
        localAIChatConversations: [SavedConversation] = [],
        activeLocalAIConversationID: UUID? = nil,
        semanticRAGEnabled: Bool = false,
        coreAIEmbeddingModelPath: String? = nil,
        rerankerEnabled: Bool = false,
        coreAIRerankerModelPath: String? = nil
    ) {
        self.masterEnabled = masterEnabled
        self.rewriteEnabled = rewriteEnabled
        self.synthesisEnabled = synthesisEnabled
        self.chatEnabled = chatEnabled
        self.ragEnabled = ragEnabled
        self.ragIncludeHistory = ragIncludeHistory
        self.ragIncludeBookmarks = ragIncludeBookmarks
        self.ragRecencyCutoff = ragRecencyCutoff
        self.ragMaxItems = ragMaxItems
        self.lowMemoryMode = lowMemoryMode
        self.idleUnloadSeconds = idleUnloadSeconds
        self.toolsEnabled = toolsEnabled
        self.disabledToolIDs = disabledToolIDs
        self.experimentalFallbacksEnabled = experimentalFallbacksEnabled
        self.ollamaModelName = ollamaModelName
        self.ollamaBaseURL = ollamaBaseURL
        self.useOllama = useOllama
        self.searxlyAIEnabled = searxlyAIEnabled
        self.useSearxlyAI = useSearxlyAI
        self.searxlyAIModelName = searxlyAIModelName
        self.searxlyAIBaseURL = searxlyAIBaseURL
        self.searxlyAIAPIKey = searxlyAIAPIKey
        self.saveLocalAIChatHistory = saveLocalAIChatHistory
        self.localAIChatConversations = localAIChatConversations
        self.activeLocalAIConversationID = activeLocalAIConversationID
        self.semanticRAGEnabled = semanticRAGEnabled
        self.coreAIEmbeddingModelPath = coreAIEmbeddingModelPath
        self.rerankerEnabled = rerankerEnabled
        self.coreAIRerankerModelPath = coreAIRerankerModelPath
    }

    static let `default` = AIPreferences() // all off

    // MARK: - Codable (custom for forward/backward compat with persisted AppData.json)
    // Old persisted data won't have "toolsEnabled" (or future fields), so we must use decodeIfPresent
    // with fallbacks. Synthesized Codable would fail with keyNotFound on missing keys even for
    // properties that have = defaults in the struct.
    //
    // This was the cause of the "Key 'toolsEnabled' not found in keyed decoding container" + backup
    // of AppData.json on first run after adding the tools feature. Existing users now safely get
    // toolsEnabled=false (opt-in, as intended).

    private enum CodingKeys: String, CodingKey {
        case masterEnabled
        case rewriteEnabled
        case synthesisEnabled
        case chatEnabled
        case ragEnabled
        case ragIncludeHistory
        case ragIncludeBookmarks
        case ragRecencyCutoff
        case ragMaxItems
        case lowMemoryMode
        case idleUnloadSeconds
        case toolsEnabled
        case disabledToolIDs
        case experimentalFallbacksEnabled
        case ollamaModelName
        case ollamaBaseURL
        case useOllama
        case searxlyAIEnabled
        case useSearxlyAI
        case searxlyAIModelName
        case searxlyAIBaseURL
        case searxlyAIAPIKey
        case saveLocalAIChatHistory
        case localAIChatConversations
        case activeLocalAIConversationID
        case semanticRAGEnabled
        case coreAIEmbeddingModelPath
        case rerankerEnabled
        case coreAIRerankerModelPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        masterEnabled = try container.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? false
        rewriteEnabled = try container.decodeIfPresent(Bool.self, forKey: .rewriteEnabled) ?? false
        synthesisEnabled = try container.decodeIfPresent(Bool.self, forKey: .synthesisEnabled) ?? false
        chatEnabled = try container.decodeIfPresent(Bool.self, forKey: .chatEnabled) ?? false
        ragEnabled = try container.decodeIfPresent(Bool.self, forKey: .ragEnabled) ?? false

        ragIncludeHistory = try container.decodeIfPresent(Bool.self, forKey: .ragIncludeHistory) ?? true
        ragIncludeBookmarks = try container.decodeIfPresent(Bool.self, forKey: .ragIncludeBookmarks) ?? true
        ragRecencyCutoff = try container.decodeIfPresent(Date.self, forKey: .ragRecencyCutoff)
        ragMaxItems = try container.decodeIfPresent(Int.self, forKey: .ragMaxItems) ?? 150

        lowMemoryMode = try container.decodeIfPresent(Bool.self, forKey: .lowMemoryMode) ?? false
        idleUnloadSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleUnloadSeconds) ?? 300

        toolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolsEnabled) ?? false
        disabledToolIDs = try container.decodeIfPresent(Set<String>.self, forKey: .disabledToolIDs) ?? []

        experimentalFallbacksEnabled = try container.decodeIfPresent(Bool.self, forKey: .experimentalFallbacksEnabled) ?? false
        ollamaModelName = try container.decodeIfPresent(String.self, forKey: .ollamaModelName) ?? "llama3.2"
        ollamaBaseURL = try container.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://127.0.0.1:11434"
        useOllama = try container.decodeIfPresent(Bool.self, forKey: .useOllama) ?? false

        searxlyAIEnabled = try container.decodeIfPresent(Bool.self, forKey: .searxlyAIEnabled) ?? false
        useSearxlyAI = try container.decodeIfPresent(Bool.self, forKey: .useSearxlyAI) ?? false
        searxlyAIModelName = try container.decodeIfPresent(String.self, forKey: .searxlyAIModelName) ?? "searxly-ai"
        searxlyAIBaseURL = try container.decodeIfPresent(String.self, forKey: .searxlyAIBaseURL) ?? "http://127.0.0.1:11434/v1"
        searxlyAIAPIKey = try container.decodeIfPresent(String.self, forKey: .searxlyAIAPIKey) ?? ""

        saveLocalAIChatHistory = try container.decodeIfPresent(Bool.self, forKey: .saveLocalAIChatHistory) ?? false
        localAIChatConversations = try container.decodeIfPresent([SavedConversation].self, forKey: .localAIChatConversations) ?? []
        activeLocalAIConversationID = try container.decodeIfPresent(UUID.self, forKey: .activeLocalAIConversationID)

        semanticRAGEnabled = try container.decodeIfPresent(Bool.self, forKey: .semanticRAGEnabled) ?? false
        coreAIEmbeddingModelPath = try container.decodeIfPresent(String.self, forKey: .coreAIEmbeddingModelPath)

        rerankerEnabled = try container.decodeIfPresent(Bool.self, forKey: .rerankerEnabled) ?? false
        coreAIRerankerModelPath = try container.decodeIfPresent(String.self, forKey: .coreAIRerankerModelPath)
    }

    // encode(to:) uses the default synthesized implementation (all current properties will be written).
}

// MARK: - Action Log (for transparency / user audit)

enum AIActionType: String, Codable, CaseIterable {
    case queryRewrite
    case synthesis
    case chatTurn
    case ragRetrieval
    case toolUse
    case modelLoad
    case modelUnload
    case settingsChange
    case error
}

struct AIAction: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let type: AIActionType
    /// Short human-readable description (e.g. "Rewrote 'best m3 macs' → 'best Apple M3 MacBook Pro 2026'")
    let summary: String
    /// Optional structured detail (never contains full page bodies for privacy).
    let detail: String?
    /// Whether the action actually produced a model call (vs no-op due to toggle).
    let usedModel: Bool

    init(type: AIActionType, summary: String, detail: String? = nil, usedModel: Bool = false) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.summary = summary
        self.detail = detail
        self.usedModel = usedModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        type = try container.decode(AIActionType.self, forKey: .type)
        summary = try container.decode(String.self, forKey: .summary)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        usedModel = try container.decode(Bool.self, forKey: .usedModel)
    }

    // Codable: id is not persisted (fresh on load for UI identity only)
    private enum CodingKeys: String, CodingKey {
        case timestamp, type, summary, detail, usedModel
    }
}

// MARK: - Citations (grounded, mechanical + prompt-enforced)

struct Citation: Codable, Identifiable, Equatable, Hashable {
    let id: Int          // 1-based index as shown to the model and user
    let title: String
    let url: String
    let engine: String?
    /// Optional short domain for display
    var domain: String {
        if let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") {
            return host
        }
        return url
    }
}

// MARK: - Synthesis Result (what we show the user)

struct AISummary: Codable, Equatable, Identifiable {
    /// Stable identity for use with .sheet(item:) and SwiftUI identity.
    let id: UUID

    let query: String
    let text: String                 // The synthesized body (may contain [1], [2] markers)
    let citations: [Citation]
    let generatedAt: Date
    /// Rough token estimate for user transparency / debugging
    let estimatedTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case query, text, citations, generatedAt, estimatedTokens
        // id is not persisted; generated at runtime
    }

    init(query: String, text: String, citations: [Citation], generatedAt: Date = Date(), estimatedTokens: Int? = nil) {
        self.id = UUID()
        self.query = query
        self.text = text
        self.citations = citations
        self.generatedAt = generatedAt
        self.estimatedTokens = estimatedTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        query = try container.decode(String.self, forKey: .query)
        text = try container.decode(String.self, forKey: .text)
        citations = try container.decode([Citation].self, forKey: .citations)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        estimatedTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedTokens)
    }
}

// MARK: - Chat Primitives

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date
    /// Sources behind a grounded answer (cloud web_search). Rendered as clickable citation chips.
    /// nil/empty for ordinary messages. Backward-compatible (decodeIfPresent).
    var sources: [Citation]?

    enum Role: String, Codable, Equatable {
        case user
        case assistant
        case system   // context injection, never shown directly to user in UI
    }

    init(role: Role, text: String, timestamp: Date = Date(), sources: [Citation]? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.sources = sources
    }

    /// Internal init for streaming updates (re-uses existing id so the bubble stays the same in the list).
    init(id: UUID, role: Role, text: String, timestamp: Date = Date(), sources: [Citation]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sources = try container.decodeIfPresent([Citation].self, forKey: .sources)
    }

    private enum CodingKeys: String, CodingKey {
        case role, text, timestamp, sources
    }
}

// Lightweight transcript for a single chat session (not full history of all chats).
struct ChatTranscript: Codable, Equatable {
    var messages: [ChatMessage] = []
    var attachedSearchQuery: String?
    var attachedResultCount: Int = 0
}

// Represents a past or current Local AI conversation.
// Stored in a list so the user can browse previous conversations via a new "Conversations" button.
struct SavedConversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "New conversation"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ChatMessage] = []
    var backend: String = "Apple Intelligence"  // e.g. "Apple Intelligence" or "Ollama (llama3.2)"
}

// MARK: - RAG

enum RAGSource: String, Codable {
    case history
    case bookmark
}

struct RAGItem: Codable, Identifiable, Equatable {
    let id: UUID
    let source: RAGSource
    let title: String
    let url: String
    let date: Date
    /// Optional short snippet (titles + URLs are usually sufficient and lower risk).
    let snippet: String?
}

// Result of a retrieval (used to augment chat or synthesis context).
struct RAGRetrieval: Codable, Equatable {
    let query: String
    let items: [RAGItem]
    let retrievedAt: Date
}

// MARK: - Availability (reported by manager, used by all UI)

enum IntelligenceAvailability: Equatable {
    case available
    case appleIntelligenceNotEnabled          // User must enable in System Settings
    case deviceNotSupported                   // Intel or insufficient hardware
    case modelNotReady                        // OS is still preparing on-device assets
    case unavailable(String)                  // Catch-all with reason
}

// MARK: - Status for UI (mirrors LocalSearxngManager style for familiarity)

enum LocalAIStatus: Equatable {
    case disabled                             // Master toggle off
    case checking
    case ready
    case generating                           // Active model work (rewrite/summarize/chat)
    case unloading
    case unavailable(IntelligenceAvailability)
    case error(String)
}