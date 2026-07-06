//
//  ChatComposer.swift
//  Searxly
//
//  The prominent, Siri-like glassy composer bar for the Local AI Chat redesign.
//  - Large floating glass pill / bar at bottom
//  - Paperclip + (optional future mic) + expandable TextField
//  - Big satisfying glass send button
//  - Horizontal action chips above (Web search, Open site)
//  - Attached files chips row
//  - Drag & drop + file picker integration hooks (passed in)
//  Fully respects glassEnabled / reduceLiquidGlass.
//  All heavy logic (send, attachments) stays in the parent sheet.
//

import SwiftUI
import UniformTypeIdentifiers

/// A locked-composer state: replaces the input with an upsell card so the user literally can't type
/// (e.g. out of today's Searxly AI prompts, or no wallet connected). The CTA drives the upgrade flow.
struct ComposerLock {
    let icon: String
    let title: String
    let message: String
    let ctaTitle: String
    let ctaAction: () -> Void
}

struct ChatComposer: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var inputText: String
    let isThinking: Bool
    let canUseFeatures: Bool
    let glassEnabled: Bool

    // Backend-aware copy (monochrome redesign)
    var placeholder: String = "Ask anything privately…"
    var footnote: String? = nil

    /// When set, the composer is LOCKED: the input is replaced by an upsell card (the user can't type),
    /// e.g. when they've used today's Searxly AI prompts.
    var lock: ComposerLock? = nil

    // Attachments (display + remove hooks)
    let attachedFiles: [ChatAttachment]
    let onRemoveAttachment: (ChatAttachment) -> Void
    let onTapAttachment: ((ChatAttachment) -> Void)?

    // Action chips (the two primary explicit tools)
    let onWebSearchChip: () -> Void
    let onOpenSiteChip: () -> Void

    // Composer actions
    let onSend: () -> Void
    let onAttachFile: () -> Void   // triggers the sheet's fileImporter

    // Drop support (forwarded from parent)
    let onDrop: ([NSItemProvider]) -> Void

    @FocusState private var isInputFocused: Bool

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sendEnabled: Bool {
        (!trimmedInput.isEmpty || !attachedFiles.isEmpty) && !isThinking && canUseFeatures
    }

    private func composerChip(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(WalletTheme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(WalletTheme.surfaceStrong))
        }
        .buttonStyle(.plain)
    }

    private func lockedCard(_ lock: ComposerLock) -> some View {
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: lock.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WalletTheme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(lock.title).font(.subheadline.weight(.semibold)).foregroundStyle(WalletTheme.textPrimary)
                    Text(lock.message).font(.caption).foregroundStyle(WalletTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button(action: lock.ctaAction) {
                Text(lock.ctaTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WalletTheme.surfaceField))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WalletTheme.hairline, lineWidth: 0.8))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let lock {
                lockedCard(lock)
            } else {
            // Action chips row (user-called tools) - only when ready
            if canUseFeatures && !isThinking {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        composerChip("magnifyingglass", "Web search", action: onWebSearchChip)
                        composerChip("safari", "Open site…", action: onOpenSiteChip)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 30)
            }

            // Attached files (if any)
            if !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFiles) { file in
                            FileAttachmentChip(attachment: file) {
                                onRemoveAttachment(file)
                            } onTap: {
                                onTapAttachment?(file)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 38)
            }

            // The composer bar — flat, monochrome (Searxly design language)
            HStack(spacing: 8) {
                Button {
                    onAttachFile()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(WalletTheme.textTertiary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(isThinking || !canUseFeatures)
                .help("Attach a local PDF, text, Markdown or CSV file (stays private)")

                TextField(placeholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(WalletTheme.textPrimary)
                    .tint(.white)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .disabled(isThinking || !canUseFeatures)
                    .onSubmit {
                        if sendEnabled { onSend() }
                    }
                    .submitLabel(.send)

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(sendEnabled ? WalletTheme.primaryText(enabled: true) : WalletTheme.textFaint)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(sendEnabled ? WalletTheme.primaryFill(enabled: true) : WalletTheme.surfaceStrong))
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WalletTheme.surfaceField))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WalletTheme.hairline, lineWidth: 0.8))

            if let footnote {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text(footnote).font(.caption2)
                }
                .foregroundStyle(WalletTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .padding(.top, 1)
            }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        // Drag & drop surface for the whole composer area
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            onDrop(providers)
            return true
        }
    }
}

// Small helper so the sheet can still use the old suggestionChip style if wanted elsewhere.
// (We can migrate the lightweight suggestion chips to glass pills in the main sheet too.)
struct SuggestionChip: View {
    let title: String
    let action: () -> Void
    let glassEnabled: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
        }
        .glassPill(glassEnabled: glassEnabled)
    }
}
