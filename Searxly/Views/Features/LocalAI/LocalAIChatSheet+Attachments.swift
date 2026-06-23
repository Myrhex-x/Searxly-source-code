//
//  LocalAIChatSheet+Attachments.swift
//  Searxly
//
//  Local file attachments for the chat composer.
//

import SwiftUI
import UniformTypeIdentifiers
import PDFKit

extension LocalAIChatSheet {
    // MARK: - File attachment support (the "adding files too, should be possible" part that makes the chat feel like a real private assistant people love)

    func addLocalFile(url: URL) {
        // Security / privacy: we only ever read files the user explicitly picked in this session.
        // We never auto-read from web pages or bookmarks.
        guard url.startAccessingSecurityScopedResource() else {
            messages.append(ChatMessage(role: .system, text: "Couldn't access the selected file (security scope)."))
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let filename = url.lastPathComponent
        var extracted = ""

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            if let doc = PDFDocument(url: url) {
                extracted = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
            }
        } else {
            // Plain text, md, csv, etc.
            if let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                extracted = str
            }
        }

        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            messages.append(ChatMessage(role: .system, text: "Attached “\(filename)” but no readable text was found (PDF image-only or binary?)."))
            return
        }

        // Budget: keep individual files reasonable and total attachments sane.
        let maxPerFile = 12_000
        let safeText = String(trimmed.prefix(maxPerFile))
        let totalChars = attachedFiles.reduce(0) { $0 + $1.extractedText.count } + safeText.count
        if totalChars > 35_000 {
            messages.append(ChatMessage(role: .system, text: "Too much attached content (kept under ~35k chars total for good on-device performance). Remove something first."))
            return
        }

        let att = ChatAttachment(
            filename: filename,
            sizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? safeText.utf8.count,
            extractedText: safeText,
            sourceHint: "local file you attached"
        )
        attachedFiles.append(att)

        // Friendly system note (stays in transcript for transparency)
        messages.append(ChatMessage(role: .system, text: "Attached local file “\(filename)” (\(att.sizeDescription) extracted). It will be used only for this private chat and cleared when you start a new one."))
    }

    func removeAttachment(_ file: ChatAttachment) {
        attachedFiles.removeAll { $0.id == file.id }
    }

    /// Sync the live messages to the active conversation in the manager's history list.
    /// This keeps previous conversations available via the "Conversations" button.
    /// Persists to disk only when the "permanently save" setting is on.
    func syncCurrentConversation(backendDesc: String? = nil) {
        let desc = backendDesc ?? currentBackendDescription
        manager.updateActiveLocalAIConversation(messages: messages, backendDescription: desc)
    }

    func handleDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                    DispatchQueue.main.async {
                        if let url = item as? URL {
                            self.addLocalFile(url: url)
                        } else if let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) {
                            self.addLocalFile(url: url)
                        }
                    }
                }
            }
        }
    }

    /// Builds the extra prompt block for any currently attached local files.
    /// Now actually called from send() and runFollowUpGeneration (P2 fix). The content excerpts
    /// (previously completely missing from the model prompt) are appended after prepareSystemPrompt
    /// so the on-device model finally receives the user's chosen local PDF/text/Markdown.
    /// The short header rule is already added by prepare via the count; we include the full block here.
    func fileContextBlockForPrompt(includeHeader: Bool = true) -> String {
        guard !attachedFiles.isEmpty else { return "" }
        var block = ""
        if includeHeader {
            block += "\n\n" + AIPromptLibrary.attachedFilesInstructions(fileCount: attachedFiles.count) + "\n"
        }
        for f in attachedFiles {
            block += "\n--- User-attached local file: \(f.filename) (\(f.sourceHint ?? "local")) ---\n"
            block += f.excerpt(maxChars: 10_000)   // per-file safety inside the global budget
            block += "\n--- End of \(f.filename) ---\n"
        }
        return block
    }

    // (Transitional adapters and old UI chip helpers were removed after the Siri-style redesign.)

    // MARK: - Explicit user-called action implementations (the two work tools only)

    func executeUserWebSearch() async {
        guard let perform = performPrivateSearch else { return }

        // Ensure SearXNG is running (same proven pattern used for the native tool closure).
        let mgr = LocalSearxngManager.shared
        if mgr.projectFolderExists {
            if await mgr.isLocalWebReady() {
                await mgr.refreshStatus()
            } else {
                await mgr.ensureReadyAndRunning()
            }
        }

        isThinking = true
        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (attachedSearchContext ?? "current topic")
            : inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        // Use the dedicated implementation in the per-tool file (clean separation for future changes).
        let resultBlock = await WebSearch.execute(query: q, using: perform)

        messages.append(ChatMessage(role: .system, text: "Action: web search (private)"))
        messages.append(ChatMessage(role: .assistant, text: resultBlock))

        await runFollowUpGeneration(
            toolResult: resultBlock,
            naturalInstruction: "Using only the fresh private search results above, give a clear, natural answer to the user's question. Cite with [N] where helpful. Do not mention the action mechanism."
        )
    }

    // Note: The "Open site…" chip does not call an executeUser method. It presets a clear
    // navigation sentence in the input field so the reliable direct-prefix bypass in send()
    // (which calls the openWebsite closure and dismisses the sheet) handles it. This is the
    // most robust path for explicit "open ..." commands.

    /// Central helper to ensure the chat UI state is always left in a usable condition
    /// after any generation, tool use, or error. Prevents stuck "thinking" or pending cards.
    func safelyResetAIState() {
        pendingToolRequest = nil
        isThinking = false
        currentFollowUpSuggestions = []
    }

    func isLastAssistantMessage(_ msg: ChatMessage) -> Bool {
        guard msg.role == .assistant else { return false }
        if let last = messages.last(where: { $0.role == .assistant }) {
            return last.id == msg.id
        }
        return false
    }

    func scrollToBottom(proxy: ScrollViewProxy) {
        safeScrollToBottom(proxy: proxy, animated: false)
    }

    /// Safe scroll that defers to next runloop tick using DispatchQueue.main.async.
    /// This is the primary mitigation for "NSHostingView is being laid out reentrantly"
    /// warnings and skipped layout passes when streaming tokens + conditional chips/tool cards
    /// + the custom chat overlay + parent WebView layout are all active at once.
    func safeScrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // Clear follow-up suggestions whenever the user is about to send something new
    // (already called in send() and clear paths).

    // Extend the existing clear path to also drop files (already wired in the "Clear chat + files" button above)
}
