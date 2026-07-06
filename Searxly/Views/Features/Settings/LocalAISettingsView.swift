//
//  LocalAISettingsView.swift
//  Searxly
//

import SwiftUI

struct LocalAISettingsView: View {
    @State private var manager = LocalIntelligenceManager.shared
    @State private var showActivityLog = false
    @State private var showRAGAudit = false

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "On-Device & Local AI",
                subtitle: "Run AI privately on your Mac — Apple Intelligence or your own Ollama model. Nothing leaves this device. (The Searxly AI cloud has its own tab.)"
            )

            SettingsSection(
                title: "Enable",
                footer: "When off, Searxly works exactly as it does without AI."
            ) {
                SettingsToggleRow(
                    title: "Searxly Agent",
                    description: "The master switch for all of Searxly's AI — on-device, local, and the Searxly AI cloud.",
                    isOn: Binding(
                        get: { manager.isEnabled },
                        set: { manager.isEnabled = $0 }
                    ),
                    badge: manager.isEnabled ? "On" : nil
                )
            }

            if manager.isLowMemoryDevice {
                SettingsCallout(
                    title: "\(manager.detectedPhysicalMemoryGB) GB RAM detected",
                    message: "This Mac has limited memory. Some Agent features are unavailable.",
                    tint: .orange,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            if manager.isEnabled {
                appleSection
                backendSection
                searchSection
                chatSection
                toolsSection
                agentToolsSection
                personalDataSection
                resourcesSection
                transparencySection
            }
        }
        .sheet(isPresented: $showActivityLog) { activityLogSheet }
        .sheet(isPresented: $showRAGAudit) { ragAuditSheet }
    }

    // MARK: - Sections

    @ViewBuilder
    private var searchSection: some View {
        SettingsSection(
            title: "Search",
            footer: "Runs locally before your query is sent to SearXNG."
        ) {
            SettingsToggleRow(
                title: "Improve search queries",
                description: "Rewrites vague queries for better results. Happens silently in the background.",
                isOn: Binding(
                    get: { manager.preferences.rewriteEnabled },
                    set: { manager.preferences.rewriteEnabled = $0; manager.persistPreferences() }
                )
            )
        }
    }

    @ViewBuilder
    private var chatSection: some View {
        SettingsSection(title: "Chat") {
            SettingsToggleRow(
                title: "Follow-up chat",
                description: "Ask questions about your current search. Stays on this Mac.",
                isOn: Binding(
                    get: { manager.preferences.chatEnabled },
                    set: { manager.preferences.chatEnabled = $0; manager.persistPreferences() }
                )
            )

            if manager.preferences.chatEnabled {
                SettingsDivider()

                SettingsToggleRow(
                    title: "Remember chats after restart",
                    description: "Off by default. When off, chat clears when you quit Searxly.",
                    isOn: Binding(
                        get: { manager.preferences.saveLocalAIChatHistory },
                        set: { newValue in
                            manager.preferences.saveLocalAIChatHistory = newValue
                            if newValue { manager.persistPreferences() }
                        }
                    )
                )

                Button {
                    NotificationCenter.default.post(name: Notification.Name("Searxly.OpenLocalAIChatRequested"), object: nil)
                } label: {
                    Label("Open chat", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!(manager.preferences.masterEnabled && manager.preferences.chatEnabled))
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        SettingsSection(
            title: "Web search",
            footer: "Only uses your private SearXNG instances."
        ) {
            SettingsToggleRow(
                title: "Let Agent search the web",
                description: "Agent can look things up during a chat. You approve each search.",
                isOn: Binding(
                    get: { manager.preferences.toolsEnabled },
                    set: { manager.preferences.toolsEnabled = $0; manager.persistPreferences() }
                )
            )
        }
    }

    @ViewBuilder
    private var agentToolsSection: some View {
        SettingsSection(
            title: "Agent tools",
            footer: "Tools the on-device model can use. Searxly AI's extra cloud tools (history, deep research, wallet, and more) are managed in the Searxly AI tab."
        ) {
            ForEach(Array(AIToolCatalog.all.filter { $0.availableOnDevice }.enumerated()), id: \.element.id) { index, tool in
                if index > 0 { SettingsDivider() }
                SettingsToggleRow(
                    title: tool.name,
                    description: tool.summary,
                    isOn: Binding(
                        get: { manager.isToolEnabled(tool.id) },
                        set: { manager.setToolEnabled(tool.id, $0) }
                    )
                )
                .disabled(!manager.preferences.toolsEnabled)
            }
        }
    }

    @ViewBuilder
    private var personalDataSection: some View {
        SettingsSection(
            title: "Your browsing data",
            footer: "Optional. Lets chat reference your history and bookmarks. Off by default."
        ) {
            SettingsToggleRow(
                title: "Use history and bookmarks in chat",
                description: manager.isLowMemoryDevice
                    ? "Not available on Macs with 8 GB RAM or less."
                    : "Agent can pull from data you allow below.",
                isOn: Binding(
                    get: { manager.preferences.ragEnabled },
                    set: { newValue in
                        if !manager.isLowMemoryDevice {
                            manager.preferences.ragEnabled = newValue
                            manager.persistPreferences()
                            if newValue {
                                rebuildRAG()
                            } else {
                                LocalIntelligenceManager.shared.clearRAGIndex()
                            }
                        }
                    }
                )
            )
            .disabled(manager.isLowMemoryDevice)

            if manager.preferences.ragEnabled {
                SettingsDivider()

                SettingsToggleRow(title: "Include history", isOn: ragHistoryBinding)
                SettingsToggleRow(title: "Include bookmarks", isOn: ragBookmarksBinding)

                HStack(spacing: 8) {
                    Button("Refresh index") { rebuildRAG() }
                    Button("Clear index") { LocalIntelligenceManager.shared.clearRAGIndex() }
                        .foregroundStyle(.red)
                    Spacer()
                    Button("View indexed items") { showRAGAudit = true }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggleRow(
                            title: "Semantic matching",
                            description: "Better recall using on-device embeddings. Falls back to keywords if unavailable.",
                            isOn: Binding(
                                get: { manager.preferences.semanticRAGEnabled },
                                set: { newValue in
                                    manager.preferences.semanticRAGEnabled = newValue
                                    manager.persistPreferences()
                                    rebuildRAG()
                                }
                            )
                        )

                        if manager.preferences.semanticRAGEnabled {
                            TextField("Embedding model path (.aimodel)", text: Binding(
                                get: { manager.preferences.coreAIEmbeddingModelPath ?? "" },
                                set: { newValue in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    manager.preferences.coreAIEmbeddingModelPath = trimmed.isEmpty ? nil : trimmed
                                    manager.persistPreferences()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }

                        SettingsToggleRow(
                            title: "Rerank results",
                            description: "More accurate matching with a small on-device reranker.",
                            isOn: Binding(
                                get: { manager.preferences.rerankerEnabled },
                                set: { newValue in
                                    manager.preferences.rerankerEnabled = newValue
                                    manager.persistPreferences()
                                    rebuildRAG()
                                }
                            )
                        )
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var backendSection: some View {
        SettingsSection(
            title: "Local · Ollama",
            footer: "Run your own open model on this Mac via Ollama — free, private, and works on any Mac (no special hardware). Requires Ollama installed and running."
        ) {
            SettingsToggleRow(
                title: "Use Ollama",
                description: "Run a local open model via Ollama instead of Apple Intelligence. Requires Ollama installed and running.",
                isOn: Binding(
                    get: { manager.preferences.experimentalFallbacksEnabled },
                    set: {
                        manager.preferences.experimentalFallbacksEnabled = $0
                        if !$0 { manager.preferences.useOllama = false }
                        manager.persistPreferences()
                        LocalIntelligenceManager.shared.noteExperimentalFallbackToggled()
                        Task { await LocalIntelligenceManager.shared.refreshAvailability() }
                    }
                )
            )

            if manager.preferences.experimentalFallbacksEnabled {
                SettingsDivider()

                TextField("Model name (e.g. qwen2.5:7b, llama3.2)", text: Binding(
                    get: { manager.preferences.ollamaModelName },
                    set: {
                        manager.preferences.ollamaModelName = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        manager.persistPreferences()
                        LocalIntelligenceManager.shared.applyLiveOllamaConfig()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)

                TextField("Server URL", text: Binding(
                    get: { manager.preferences.ollamaBaseURL },
                    set: {
                        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        manager.preferences.ollamaBaseURL = trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed
                        manager.persistPreferences()
                        LocalIntelligenceManager.shared.applyLiveOllamaConfig()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)

                if ollamaEndpointIsRemote {
                    SettingsCallout(
                        title: "Remote Ollama endpoint active",
                        message: "Your AI prompts, chat messages, and any page content you share go over the network to \(ollamaEndpointHost). Only use a server you control and trust.",
                        tint: .orange,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                } else {
                    Text("Only use a server you control. Remote URLs send your messages off this Mac.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// True when the configured Ollama URL points somewhere other than this Mac.
    private var ollamaEndpointIsRemote: Bool {
        guard let host = URL(string: manager.preferences.ollamaBaseURL)?.host?.lowercased() else { return false }
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private var ollamaEndpointHost: String {
        URL(string: manager.preferences.ollamaBaseURL)?.host ?? "the remote server"
    }

    @ViewBuilder
    private var appleSection: some View {
        SettingsSection(
            title: "On-device · Apple Intelligence",
            footer: "Runs entirely on this Mac — the most private option, and free. Needs Apple Silicon and macOS 26 with Apple Intelligence turned on."
        ) {
            Text(manager.statusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .unavailable(let reason) = manager.status {
                switch reason {
                case .appleIntelligenceNotEnabled:
                    Button("Open Apple Intelligence settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligence") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                case .deviceNotSupported:
                    Text("This Mac can't run Apple Intelligence. Use **Local · Ollama** below (any Mac), or **Searxly AI** in its own tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        SettingsSection(title: "Memory") {
            SettingsToggleRow(
                title: "Low-memory mode",
                description: manager.isLowMemoryDevice
                    ? "Forced on for this Mac."
                    : "Uses smaller context and fewer indexed items.",
                isOn: Binding(
                    get: { manager.isLowMemoryDevice || manager.preferences.lowMemoryMode },
                    set: { if !manager.isLowMemoryDevice { manager.preferences.lowMemoryMode = $0; persistGranular() } }
                )
            )
            .disabled(manager.isLowMemoryDevice)

            Button("Free memory now") {
                Task { await manager.unloadAll() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var transparencySection: some View {
        SettingsSection(title: "Activity") {
            HStack(spacing: 8) {
                Button("View session log") { showActivityLog = true }
                Button("Copy debug info") { LocalIntelligenceManager.shared.copyLocalAIDiagnostics() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Turn off Agent and clear data") {
                manager.isEnabled = false
                Task { await manager.unloadAll() }
                manager.clearRecentActions()
                manager.clearCurrentChatTranscript()
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
    }


    // MARK: - Sheets

    private var activityLogSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent activity this session")
                .font(.headline)

            if manager.recentActions.isEmpty {
                Text("No actions recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    ForEach(manager.recentActions) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(action.timestamp.formatted(date: .abbreviated, time: .shortened)) — \(action.type.rawValue)")
                                .font(.caption.bold())
                            Text(action.summary).font(.caption)
                            if let d = action.detail {
                                Text(d).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Button("Copy") { AIActivityLog.copyToPasteboard(manager.recentActions) }
                Button("Clear") { manager.clearRecentActions() }
                Spacer()
                Button("Done") { showActivityLog = false }
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 300)
    }

    private var ragAuditSheet: some View {
        let items = LocalIntelligenceManager.shared.getCurrentRAGItems()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Indexed items (\(items.count))")
                    .font(.headline)
                Spacer()
                Button("Done") { showRAGAudit = false }
            }
            if items.isEmpty {
                Text("Nothing indexed yet. Enable the feature above and tap Refresh index.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    ForEach(items.prefix(50)) { item in
                        HStack {
                            Text(item.source == .history ? "History" : "Bookmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.date, style: .date).font(.caption2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 300)
    }

    // MARK: - Helpers

    private var ragHistoryBinding: Binding<Bool> {
        Binding(
            get: { manager.preferences.ragIncludeHistory },
            set: { newValue in
                manager.preferences.ragIncludeHistory = newValue
                persistGranular()
                if manager.preferences.ragEnabled { rebuildRAG() }
            }
        )
    }

    private var ragBookmarksBinding: Binding<Bool> {
        Binding(
            get: { manager.preferences.ragIncludeBookmarks },
            set: { newValue in
                manager.preferences.ragIncludeBookmarks = newValue
                persistGranular()
                if manager.preferences.ragEnabled { rebuildRAG() }
            }
        )
    }

    private func rebuildRAG() {
        let data = Persistence.load()
        LocalIntelligenceManager.shared.rebuildRAGIndex(history: data.history, bookmarks: data.bookmarks)
    }

    private func persistGranular() {}
}