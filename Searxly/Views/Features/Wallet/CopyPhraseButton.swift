//
//  CopyPhraseButton.swift
//  Searxly
//
//  Backup option for the recovery phrase: copy the 12 words to the clipboard so the user can paste
//  them wherever they keep secrets (password manager, encrypted note, etc.). Replaces the old
//  encrypted-file export — per product decision, copy-to-clipboard is the only built-in backup option.
//
//  For safety the clipboard is auto-cleared after a short window (a plaintext seed should not linger).
//

import SwiftUI
import AppKit

struct CopyPhraseButton: View {
    let words: [String]

    @State private var copied = false

    /// Seconds the phrase is allowed to sit on the clipboard before we wipe it.
    private let clearAfter = 90

    private var phrase: String { words.joined(separator: " ") }

    var body: some View {
        VStack(spacing: 6) {
            Button { copyToClipboard() } label: {
                Label(copied ? "Copied — clears in \(clearAfter)s" : "Copy to clipboard",
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Paste your 12 words somewhere safe — a password manager or an encrypted note. For your safety the clipboard is automatically cleared after \(clearAfter) seconds.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(phrase, forType: .string)
        withAnimation { copied = true }

        let captured = phrase
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(clearAfter))
            // Only wipe if our phrase is still there — don't clobber something the user copied later.
            if NSPasteboard.general.string(forType: .string) == captured {
                NSPasteboard.general.clearContents()
            }
            withAnimation { copied = false }
        }
    }
}
