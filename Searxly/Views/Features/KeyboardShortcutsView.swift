//
//  KeyboardShortcutsView.swift
//  Searxly
//

import SwiftUI

struct KeyboardShortcutsView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header — only "Done" handles .cancelAction so ESC isn't ambiguous.
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Tabs & Navigation") {
                        row("⌘ T",        "New Tab (address bar ready to type)")
                        row("⌘ ⇧ T",     "New Private Tab (address bar ready to type)")
                        row("⌘ ⇧ Z",     "Reopen Last Closed Tab")
                        row("⌘ ⇧ M",     "Mute / Unmute Tab")
                        row("⌘ W",       "Close Tab")
                        row("⌃ ⇥",       "Next Tab")
                        row("⌃ ⇧ ⇥",    "Previous Tab")
                        row("⌘ 1 – 9",   "Jump to Tab by Position")
                        row("⌘ S",       "Toggle Sidebar (auto-hide: pin open / peeker; hover also expands)")
                        row("⌘ L",       "Focus Address Bar")
                        row("⌘ R",       "Reload Page")
                        row("⌘ .",       "Stop Loading")
                        row("⌘ [",       "Go Back")
                        row("⌘ ]",       "Go Forward")
                    }

                    section("Page") {
                        row("⌘ F",        "Find in Page")
                        row("⌘ D",        "Bookmark This Page")
                        row("⌘ P",        "Print Page")
                        row("⌘ +",        "Zoom In")
                        row("⌘ –",        "Zoom Out")
                        row("⌘ 0",        "Reset Zoom")
                        row("Space",      "Scroll Down")
                        row("⇧ Space",    "Scroll Up")
                        row("⌘ ↑",        "Scroll to Top")
                        row("⌘ ↓",        "Scroll to Bottom")
                        row("⌘ A",        "Select All")
                        row("⌘ C",        "Copy Selection")
                    }

                    section("App") {
                        row("⌘ ,",     "Open Settings")
                        row("⌘ ?",     "Keyboard Shortcuts")
                        row("! bang",  "Search Bang (!g, !yt, !gh, !r, !so…)")
                        row("⌘ ⌥ L",  "Lock Searxly")
                        row("⌘ ⌥ A",  "Local AI Chat")
                        row("⌘ ⌥ P",  "Toggle Privacy Mode")
                        row("⌘ ⇧ H",  "History")
                        row("Esc",     "Close Panels / Cancel")
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(width: 420)
        .frame(minHeight: 360, maxHeight: 580)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
                .padding(.bottom, 2)
            content()
        }
    }

    @ViewBuilder
    private func row(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys.components(separatedBy: " "), id: \.self) { key in
                    if key == "+" || key == "/" {
                        Text(key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(key)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                                    )
                            )
                    }
                }
            }
            .frame(minWidth: 100, alignment: .trailing)

            Text(description)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    KeyboardShortcutsView(isPresented: .constant(true))
}
