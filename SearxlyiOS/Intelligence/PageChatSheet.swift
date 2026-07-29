//
//  PageChatSheet.swift
//  SearxlyiOS
//
//  "Ask About This Page": a multi-turn, fully on-device chat whose context is the page the
//  user is reading. The session (and the page text) never touches the network. Monochrome
//  bubbles, streaming answers, starter questions.
//

import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

struct PageChatSheet: View {
    /// What grounds the chat: the live page's text, or the SERP's top-result snippets
    /// (the AI Overview's "Ask more" — same grounding, zero new egress).
    enum Context {
        case page(BrowserModel)
        case searchResults(query: String, results: [SearXNGResult])
    }
    let context: Context
    /// Auto-sent as the first message once the engine is ready (the edit menu's "Explain This").
    private let initialQuestion: String?
    @Environment(\.dismiss) private var dismiss

    private var appearance = AppearanceSettings.shared

    init(model: BrowserModel, initialQuestion: String? = nil) {
        context = .page(model)
        self.initialQuestion = initialQuestion
    }

    init(searchQuery: String, results: [SearXNGResult]) {
        context = .searchResults(query: searchQuery, results: results)
        initialQuestion = nil
    }

    private var navigationTitle: String {
        switch context {
        case .page: L("Ask About This Page")
        case .searchResults: L("Ask About These Results")
        }
    }

    private var contextTitle: String {
        switch context {
        case .page(let model):
            model.pageTitle.isEmpty ? (model.webView.url?.host ?? "") : model.pageTitle
        case .searchResults(let query, _):
            "\u{201C}\(query)\u{201D}"
        }
    }

    private struct Message: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var isResponding = false
    @State private var pageUnavailable = false
    @State private var chat: PageChatEngine?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty && !pageUnavailable {
                                starters
                            }
                            if pageUnavailable {
                                Text(L("There isn't enough readable text on this page to summarize."))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(Brand.textSecondary)
                                    .padding(.top, 20)
                            }
                            ForEach(messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: messages.last?.text) {
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                inputBar
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
        }
        .presentationDetents([.large])
        .task {
            await prepare()
            if let question = initialQuestion, messages.isEmpty, chat != nil {
                send(String(format: L("Explain this passage from the page: “%@”"), question))
            }
        }
    }

    // MARK: - Pieces

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contextTitle)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Brand.text)
                .lineLimit(2)
            ForEach([L("What are the key points?"), L("Explain this simply"), L("Any caveats or criticism mentioned?")], id: \.self) { starter in
                Button { send(starter) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "apple.intelligence")
                            .font(.system(size: 11, weight: .semibold))
                            .symbolRenderingMode(.multicolor)
                        Text(starter)
                            .font(.system(size: 13 * appearance.textScale))
                            .foregroundStyle(Brand.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 14 * appearance.textScale))
                .foregroundStyle(message.isUser ? Brand.bg : Brand.text)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    message.isUser ? AnyShapeStyle(Brand.text) : AnyShapeStyle(Brand.surface),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .overlay {
                    // Hairline rim on assistant bubbles so they hold their shape on the flat bg.
                    if !message.isUser {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Brand.hairline, lineWidth: 0.5)
                    }
                }
                .accessibilityLabel("\(message.isUser ? L("You") : L("Answer")): \(message.text)")
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 9) {
            TextField(L("Ask about this page…"), text: $input)
                .textFieldStyle(.plain)
                .scaledFont(size: 15)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Brand.surface, in: Capsule())

            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledFont(size: 28)
                    .foregroundStyle(canSend ? Brand.text : Brand.text.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty && !isResponding && chat != nil
    }

    // MARK: - Engine

    private func prepare() async {
        guard chat == nil else { return }
        switch context {
        case .page(let model):
            guard let text = await PageIntelligence.pageText(from: model.webView) else {
                pageUnavailable = true
                return
            }
            chat = PageChatEngine(pageTitle: model.pageTitle, pageText: text)
        case .searchResults(let query, let results):
            let grounding = SearchIntelligence.groundingBlock(for: results)
            guard !grounding.isEmpty else {
                pageUnavailable = true
                return
            }
            chat = PageChatEngine(searchQuery: query, grounding: grounding)
        }
    }

    private func send(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, let chat else { return }
        input = ""
        messages.append(Message(isUser: true, text: question))
        messages.append(Message(isUser: false, text: ""))
        isResponding = true

        Task {
            do {
                for try await snapshot in chat.reply(to: question) {
                    if let idx = messages.lastIndex(where: { !$0.isUser }) {
                        messages[idx].text = snapshot
                    }
                }
            } catch {
                if let idx = messages.lastIndex(where: { !$0.isUser }), messages[idx].text.isEmpty {
                    messages[idx].text = PageIntelligence.friendlyError(error)
                }
            }
            isResponding = false
        }
    }
}

// MARK: - Multi-turn session wrapper

/// Owns one LanguageModelSession seeded with the page — turns share the transcript, so
/// follow-up questions ("and why?") work naturally.
@MainActor
final class PageChatEngine {
    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif
    private let pageTitle: String
    private let pageText: String
    /// SERP mode: the grounding is numbered result snippets, and the instructions say so.
    private let isSearchGrounded: Bool

    init(pageTitle: String, pageText: String) {
        self.pageTitle = pageTitle
        // Leave headroom in the ~4k-token window for the conversation itself.
        self.pageText = String(pageText.prefix(7_000))
        self.isSearchGrounded = false
    }

    init(searchQuery: String, grounding: String) {
        self.pageTitle = searchQuery
        self.pageText = String(grounding.prefix(7_000))
        self.isSearchGrounded = true
    }

    func reply(to question: String) -> AsyncThrowingStream<String, Error> {
        #if DEBUG
        if SearchIntelligence.debugMocked {
            return SearchIntelligence.mockStream(
                "On-device mock answer about “\(pageTitle)”: \(question) — grounded in the page text, streaming word by word for UI verification."
            )
        }
        #endif

        #if canImport(FoundationModels)
        if session == nil {
            let uiName = AppLocale.shared.languageNameForModel
            let uiCode = AppLocale.shared.languageCode
            let instructions: String
            if isSearchGrounded {
                instructions = """
                You answer questions about a web search using ONLY the numbered result snippets \
                below — never outside knowledge. Cite the snippets you used inline, like [1] or \
                [2][4]. If the snippets don't contain the answer, say so plainly. Be concise. \
                Match the user's language when clear; if ambiguous, answer in \(uiName) \
                (language code: \(uiCode)).

                Search query: "\(pageTitle)"
                Results:
                \(pageText)
                """
            } else {
                instructions = """
                You answer questions about ONE web page using ONLY its text below. If the page \
                doesn't contain the answer, say so plainly. Be concise. Match the user's language \
                when clear; if ambiguous, answer in \(uiName) (language code: \(uiCode)).

                Page title: \(pageTitle)
                Page text:
                \(pageText)
                """
            }
            session = LanguageModelSession(instructions: instructions)
        }
        guard let session else {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: question) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: NSError(
                domain: "Searxly.Intelligence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available."]
            ))
        }
        #endif
    }
}
