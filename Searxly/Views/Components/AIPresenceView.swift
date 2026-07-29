//
//  AIPresenceView.swift
//  Searxly
//
//  A small in-chrome pill that shows, inside Searxly, that the user's connected AI (Claude Code, Claude
//  Desktop, a local MCP client) is hooked up and working. The chat itself lives in the AI's own app —
//  this is the in-Searxly signal that it's alive, plus a one-tap jump to the connect/manage flow.
//  Shown only when Agentic Tools is on.
//

import SwiftUI

struct AIPresenceView: View {
    var manager = AgenticServerManager.shared
    /// Opens the Agentic Tools settings (connect details, activity, toggles).
    var onOpen: () -> Void

    var body: some View {
        let presence = manager.aiPresence
        Group {
            if presence != .off {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        indicator(presence)
                        Text(label(presence))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help(helpText(presence))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: presence)
    }

    @ViewBuilder
    private func indicator(_ p: AgenticServerManager.AIPresence) -> some View {
        switch p {
        case .acting:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 11, height: 11)
        case .connected:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        case .ready:
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
        case .off:
            EmptyView()
        }
    }

    private func label(_ p: AgenticServerManager.AIPresence) -> String {
        switch p {
        case .acting:    return "AI working…"
        case .connected: return "AI connected"
        case .ready:     return "AI ready"
        case .off:       return ""
        }
    }

    private func helpText(_ p: AgenticServerManager.AIPresence) -> String {
        switch p {
        case .ready:     return "Agentic Tools is on and waiting for your AI app to connect. Click to see how."
        case .connected: return "Your AI app is connected — it can search, read, and drive this browser. Click to manage."
        case .acting:    return "Your AI just used a tool. Click to watch the activity."
        case .off:       return ""
        }
    }
}
