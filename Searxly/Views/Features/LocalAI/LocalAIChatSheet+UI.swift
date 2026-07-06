//
//  LocalAIChatSheet+UI.swift
//  Searxly
//
//  Chat sheet header, bubbles, tool confirmation, and conversation list UI.
//

import SwiftUI

extension LocalAIChatSheet {

    // MARK: - Header pieces (monochrome)

    /// Segmented model switch (On-device / Local / Searxly AI), styled like the wallet's segmented pill.
    @ViewBuilder
    var modelSwitcher: some View {
        let showSwitcher = manager.preferences.experimentalFallbacksEnabled || manager.preferences.searxlyAIEnabled
        if showSwitcher {
            HStack(spacing: 2) {
                segment("On-device", selected: activeBackend == .apple) { switchModel(to: .apple) }
                if manager.preferences.experimentalFallbacksEnabled {
                    segment("Local", selected: activeBackend == .ollama) { switchModel(to: .ollama) }
                }
                if manager.preferences.searxlyAIEnabled {
                    segment("Searxly AI", selected: activeBackend == .searxly) { switchModel(to: .searxly) }
                }
            }
            .padding(3)
            .background(Capsule().fill(WalletTheme.surfaceField))
        }
    }

    func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(selected ? WalletTheme.primaryText(enabled: true) : WalletTheme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? WalletTheme.primaryFill(enabled: true) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    func headerIcon(_ system: String, help: String, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(WalletTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(emphasized ? WalletTheme.surfaceStrong : WalletTheme.surface))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Backend-aware copy

    var backendStatusText: String {
        switch activeBackend {
        case .searxly: return "Cloud"
        case .ollama:  return "On your Mac"
        case .apple:   return "On-device"
        }
    }

    var emptyStateSubtitle: String {
        switch activeBackend {
        case .searxly: return "A private assistant, right in your browser. Ask anything, search the web privately, or read the page you're on."
        case .ollama:  return "Private AI running on your Mac. Nothing leaves this device."
        case .apple:   return "Private on-device AI. Nothing leaves this Mac."
        }
    }

    var composerPlaceholder: String {
        activeBackend == .searxly ? "Message Searxly AI…" : "Ask anything privately…"
    }

    var composerFootnote: String {
        switch activeBackend {
        case .searxly:
            return SearxlyAIAccess.shared.isWalletVerified
                ? "Searxly AI runs in a private cloud · some prompts free"
                : "Connect your wallet to use Searxly AI · free, no payment — just anti-abuse"
        case .ollama:  return "Runs on your Mac · stays private"
        case .apple:   return "On-device · nothing leaves this Mac"
        }
    }

    /// When on Searxly AI and the user can't send (no connected wallet, or out of today's prompts), the
    /// composer LOCKS and shows an upsell card instead of the input — so it's obvious they're out.
    var composerLock: ComposerLock? {
        guard activeBackend == .searxly, manager.canUseFeatures else { return nil }
        let access = SearxlyAIAccess.shared
        if !access.isWalletVerified {
            return ComposerLock(
                icon: "wallet.pass",
                title: "Connect your wallet to use Searxly AI",
                message: "It's free — no payment, no funds move. Just a one-tap signature so the free prompts can't be abused.",
                ctaTitle: "Connect wallet in Settings",
                ctaAction: { openSearxlyAISettings() }
            )
        }
        if access.promptsRemainingToday <= 0 {
            return ComposerLock(
                icon: "bolt.slash.fill",
                title: "Out of prompts for today",
                message: "You've used today's \(access.dailyLimit) Searxly AI prompts. Upgrade for more, or they reset at your local midnight.",
                ctaTitle: "Upgrade for more prompts",
                ctaAction: { openSearxlyAISettings() }
            )
        }
        return nil
    }

    /// Closes the chat and deep-links to Settings → Searxly AI (where the upgrade / wallet flow lives).
    func openSearxlyAISettings() {
        isPresented = false
        NotificationCenter.default.post(name: .openSettingsToSearxlyAI, object: nil)
    }

    var showTypingIndicator: Bool {
        guard isThinking else { return false }
        guard let last = messages.last else { return true }
        if last.role == .user { return true }
        if last.role == .assistant && last.text.isEmpty { return true }
        return false
    }

    func examplePrompt(_ text: String) -> some View {
        Button {
            // Populate the composer instead of auto-sending.
            // User can edit the prompt (e.g. replace "this topic") and then send.
            inputText = text
        } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(WalletTheme.textSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WalletTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WalletTheme.hairline, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func chatBubble(for msg: ChatMessage) -> some View {
        if msg.role == .user {
            // User — right-aligned monochrome bubble (no accent color, no glass)
            HStack {
                Spacer(minLength: 48)
                Text(msg.text)
                    .textSelection(.enabled)
                    .font(.callout)
                    .foregroundStyle(WalletTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WalletTheme.surfaceStrong))
                    .frame(maxWidth: 460, alignment: .trailing)
            }
        } else {
            // Assistant — full-width with the Searxly mark (modern AI-chat look)
            HStack(alignment: .top, spacing: 11) {
                SearxlyChatMark(color: WalletTheme.textSecondary, lineWidth: 1.4)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg.text)
                        .textSelection(.enabled)
                        .font(.callout)
                        .foregroundStyle(WalletTheme.textPrimary.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sources = msg.sources, !sources.isEmpty {
                        sourcesFooter(sources)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Clickable citation chips under a grounded (cloud) answer. Tapping opens the exact source URL
    /// in a new Searxly tab. Monochrome to match the chat (brand: black & white).
    @ViewBuilder
    func sourcesFooter(_ sources: [Citation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WalletTheme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { citation in
                        Button {
                            openURLInTab?(citation.url)
                        } label: {
                            HStack(spacing: 5) {
                                Text("[\(citation.id)]")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(WalletTheme.textPrimary)
                                Text(citation.domain)
                                    .font(.caption2)
                                    .foregroundStyle(WalletTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(WalletTheme.surfaceField))
                            .overlay(Capsule().strokeBorder(WalletTheme.hairline, lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)
                        .help(citation.title)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    func toolConfirmationCard(for pending: PendingToolRequest) -> some View {
        let details = toolConfirmationDetails(for: pending)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: details.icon)
                    .font(.title3)
                Text(details.headline)
                    .font(.headline)
            }
            .foregroundStyle(WalletTheme.textPrimary)

            Text(details.body)
                .font(.caption)
                .foregroundStyle(WalletTheme.textSecondary)

            Text(details.payloadLine)
                .font(.callout)
                .foregroundStyle(WalletTheme.textPrimary)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WalletTheme.surfaceField))

            HStack {
                Button("Cancel") { safelyResetAIState() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(WalletTheme.surfaceStrong))

                Spacer()

                Button {
                    confirmToolUse(pending)
                } label: {
                    Label(details.approveLabel, systemImage: details.icon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(WalletTheme.primaryText(enabled: true))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(WalletTheme.primaryFill(enabled: true)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WalletTheme.canvasRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WalletTheme.hairline, lineWidth: 0.7))
    }

    var conversationsListSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Previous Searxly Agent Conversations")
                    .font(.headline)
                Spacer()
                Button("Done") { showingConversationsList = false }
                    .glassPill(glassEnabled: glassEnabled)
            }

            if manager.preferences.localAIChatConversations.isEmpty {
                Text("No previous conversations yet. Start chatting — the model picker or 'New' always starts fresh.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                List {
                    ForEach(manager.preferences.localAIChatConversations) { conv in
                        Button {
                            if LocalIntelligenceManager.shared.loadLocalAIConversation(id: conv.id) {
                                messages = conv.messages
                            }
                            showingConversationsList = false
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conv.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(conv.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(conv.backend).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(conv.messages.count) messages").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indices in
                        for index in indices {
                            let id = manager.preferences.localAIChatConversations[index].id
                            LocalIntelligenceManager.shared.deleteLocalAIConversation(id: id)
                        }
                    }
                }
                .listStyle(.plain)
            }

            HStack {
                Button("New Conversation") {
                    startNewConversation()
                    showingConversationsList = false
                }
                .glassPill(glassEnabled: glassEnabled)

                Spacer()

                if !manager.preferences.localAIChatConversations.isEmpty {
                    Button("Delete All") {
                        LocalIntelligenceManager.shared.clearAllLocalAIConversations()
                        messages.removeAll()
                        showingConversationsList = false
                    }
                    .foregroundStyle(.red)
                    .glassPill(glassEnabled: glassEnabled)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 340)
    }
}
