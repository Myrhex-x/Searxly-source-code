//
//  QuickAnswerPopup.swift
//  Searxly
//
//  A lightweight, Siri-style quick answer for "Explain selection" / "Summarize selection" from the
//  page right-click menu. It streams a short answer in a small floating card instead of opening the
//  full chat. A "Talk to Searxly" button hands the Q&A off into the full chat to continue.
//
//  Routing lives in BrowserState.handleAskAISelection: .ask → full chat; .explain/.summarize → this.
//

import SwiftUI

/// A pending quick-answer request. For page summaries `selection` holds the (untrusted) extracted
/// page text and `pageTitle`/`pageURL` are set. Identity drives fresh popup state.
struct QuickAnswerRequest: Identifiable, Equatable {
    let id = UUID()
    let selection: String
    let action: AIChatSeed.Action   // .explain / .summarize / .summarizePage (ask uses the full chat)
    var pageTitle: String? = nil
    var pageURL: String? = nil
    /// When set, the card just displays this message (no generation) — e.g. cloud paused in a Private tab.
    var staticNotice: String? = nil
}

enum QuickAnswer {
    static func label(for action: AIChatSeed.Action) -> String {
        switch action {
        case .explain:        return "Explain"
        case .summarize:      return "Summary"
        case .summarizePage:  return "Page summary"
        case .ask:            return "Ask"
        }
    }
}

/// Overlay wrapper: renders the card only when a request is pending. `.id` gives each request fresh state.
struct QuickAnswerPopup: View {
    @Bindable var browserState: BrowserState
    var glassEnabled: Bool

    var body: some View {
        if let req = browserState.quickAnswer {
            QuickAnswerCard(request: req, browserState: browserState, glassEnabled: glassEnabled)
                .id(req.id)
                .padding(18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.34, dampingFraction: 0.85), value: req.id)
        }
    }
}

private struct QuickAnswerCard: View {
    let request: QuickAnswerRequest
    @Bindable var browserState: BrowserState
    var glassEnabled: Bool

    @State private var answer: String = ""
    @State private var isStreaming: Bool = true
    @State private var task: Task<Void, Never>? = nil

    private var manager: LocalIntelligenceManager { .shared }

    private var isCloudActive: Bool {
        manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI
    }
    /// A static-notice card (e.g. cloud paused in a Private tab) shows no Talk/Copy footer.
    private var isNotice: Bool { request.staticNotice != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(WalletTheme.hairline)
            answerBody
            if !isNotice {
                Divider().overlay(WalletTheme.hairline)
                footer
            }
        }
        .frame(width: 430)
        .frame(maxHeight: 480)
        // Real macOS Liquid Glass so the popup reads as native chrome (matches the rest of the app).
        .background {
            if !glassEnabled {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WalletTheme.canvasRaised)
            }
        }
        .searxlyGlass(glassEnabled ? .regular : .clear,
                     in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(WalletTheme.hairline, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.20), radius: 22, x: 0, y: 10)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            SearxlyChatMark(color: WalletTheme.textSecondary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            Text("Searxly AI")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalletTheme.textPrimary)
            Text("· \(QuickAnswer.label(for: request.action))")
                .font(.subheadline)
                .foregroundStyle(WalletTheme.textSecondary)
            if isCloudActive {
                Text("Cloud")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(WalletTheme.surfaceStrong))
                    .help("Generated on Searxly's cloud — this content is sent off your Mac.")
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .padding(5)
                    .background(Circle().fill(WalletTheme.surfaceStrong))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var answerBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if answer.isEmpty && isStreaming {
                    TypingDots(color: WalletTheme.textSecondary)
                        .padding(.vertical, 2)
                } else {
                    Text(answer)
                        .textSelection(.enabled)
                        .font(.callout)
                        .foregroundStyle(WalletTheme.textPrimary.opacity(0.94))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                talkToSearxly()
            } label: {
                Label("Talk to Searxly", systemImage: "bubble.left.and.bubble.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(WalletTheme.primaryText(enabled: true))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(WalletTheme.primaryFill(enabled: true)))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                copyAnswer()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(WalletTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(WalletTheme.surfaceStrong))
            }
            .buttonStyle(.plain)
            .disabled(answer.isEmpty)
            .help("Copy answer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Actions

    private func start() {
        // Static notice (e.g. cloud paused in a Private tab) — just show it, never generate.
        if let notice = request.staticNotice {
            isStreaming = false
            answer = notice
            return
        }

        manager.warmUpIfNeeded()
        guard manager.canUseFeatures else {
            isStreaming = false
            answer = "Turn on Searxly AI in Settings to use quick answers."
            return
        }

        // Page extraction came back empty (SPA / blocked) → graceful message.
        if request.action == .summarizePage,
           request.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isStreaming = false
            answer = "I couldn't read any readable text from this page."
            return
        }

        let engine = ConversationEngine()
        let isCloud = manager.preferences.searxlyAIEnabled && manager.preferences.useSearxlyAI

        // Meter Searxly AI cloud usage. A whole-page summary ships the full page, so it costs more.
        if isCloud {
            if !SearxlyAIAccess.shared.isWalletVerified {
                isStreaming = false
                answer = SearxlyAIAccess.shared.walletRequiredMessage
                return
            }
            SearxlyAIAccess.shared.refreshDailyWindow()
            if !SearxlyAIAccess.shared.canSendPromptToday {
                isStreaming = false
                answer = SearxlyAIAccess.shared.limitReachedMessage
                return
            }
            SearxlyAIAccess.shared.recordPromptUse(count: request.action == .summarizePage ? 3 : 1)
        }

        // ALL quick-answer actions run through the hardened, injection-resistant guard (no tools,
        // nonce-delimited untrusted-data framing) — including selection Explain/Summarize, since a
        // user could ⌘A-select hidden page text.
        let guardTask: PageContentGuard.Task = {
            switch request.action {
            case .summarizePage:        return .summarizePage
            case .summarize:            return .summarizeText
            case .explain, .ask:        return .explainText   // .ask never reaches the popup; safe default
            }
        }()
        let nonce = PageContentGuard.makeNonce()
        let sanitized = PageContentGuard.sanitize(request.selection)
        let suspected = PageContentGuard.looksLikeInjection(sanitized)
        let system = PageContentGuard.systemPrompt(nonce: nonce, injectionSuspected: suspected, isCloud: isCloud, task: guardTask)
        let prompt = PageContentGuard.userBlock(content: sanitized, nonce: nonce,
                                                title: request.pageTitle ?? "", url: request.pageURL ?? "", task: guardTask)

        task = Task { @MainActor in
            do {
                let stream = engine.generateStream(prompt: prompt, instructions: system)
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    answer += chunk
                }
                answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                isStreaming = false
            } catch {
                isStreaming = false
                if answer.isEmpty {
                    // error.localizedDescription is sanitized for the cloud provider (brand-safe).
                    let msg = (error as NSError).localizedDescription
                    answer = msg.isEmpty ? "Searxly AI couldn’t answer that. Try again." : msg
                }
            }
        }
    }

    private func talkToSearxly() {
        task?.cancel()
        let polished = answer.trimmingCharacters(in: .whitespacesAndNewlines)

        // SECURITY: for a page summary, NEVER carry the raw (untrusted) page text into the chat — the
        // chat can have tools enabled. Only the model's own summary + a short page label cross over.
        let seedSelection: String
        if request.action == .summarizePage {
            seedSelection = request.pageTitle?.isEmpty == false
                ? request.pageTitle!
                : (request.pageURL ?? "this page")
        } else {
            seedSelection = request.selection
        }

        browserState.pendingAIChatSeed = AIChatSeed(
            selection: seedSelection,
            action: request.action,
            priorAnswer: polished.isEmpty ? nil : polished
        )
        browserState.quickAnswer = nil
        browserState.openLocalAIChat()
    }

    private func copyAnswer() {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func dismiss() {
        task?.cancel()
        browserState.quickAnswer = nil
    }
}
