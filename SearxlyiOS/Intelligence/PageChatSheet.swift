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
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    private var appearance = AppearanceSettings.shared

    init(model: BrowserModel) {
        self.model = model
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
                                    .font(.system(size: 14))
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
            .navigationTitle(L("Ask About This Page"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .tint(Brand.text)
        }
        .presentationDetents([.large])
        .task { await prepare() }
    }

    // MARK: - Pieces

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.pageTitle.isEmpty ? (model.webView.url?.host ?? "") : model.pageTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.text)
                .lineLimit(2)
            ForEach([L("What are the key points?"), L("Explain this simply"), L("Any caveats or criticism mentioned?")], id: \.self) { starter in
                Button { send(starter) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.textTertiary)
                        Text(starter)
                            .font(.system(size: 13.5 * appearance.textScale))
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
                .font(.system(size: 14.5 * appearance.textScale))
                .foregroundStyle(message.isUser ? Brand.bg : Brand.text)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    message.isUser ? AnyShapeStyle(Brand.text) : AnyShapeStyle(Brand.surface),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 9) {
            TextField(L("Ask about this page…"), text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
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
                    .font(.system(size: 28))
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
        guard let text = await PageIntelligence.pageText(from: model.webView) else {
            pageUnavailable = true
            return
        }
        chat = PageChatEngine(pageTitle: model.pageTitle, pageText: text)
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
                    messages[idx].text = error.localizedDescription
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

    init(pageTitle: String, pageText: String) {
        self.pageTitle = pageTitle
        // Leave headroom in the ~4k-token window for the conversation itself.
        self.pageText = String(pageText.prefix(7_000))
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
            session = LanguageModelSession(instructions: """
            You answer questions about ONE web page using ONLY its text below. If the page \
            doesn't contain the answer, say so plainly. Be concise. Match the user's language.

            Page title: \(pageTitle)
            Page text:
            \(pageText)
            """)
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
