//
//  LocalAIChatAuxiliaryViews.swift
//  Searxly
//

import SwiftUI

// MARK: - Tools List (new transparency feature for the chatbot)

struct ToolsListSheet: View {
    let glassEnabled: Bool
    let onDismiss: () -> Void

    private let manager = LocalIntelligenceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Available Tools")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onDismiss)
                    .glassPill(glassEnabled: glassEnabled)
                    .controlSize(.small)
            }

            Toggle("AI tool calling", isOn: Binding(
                get: { manager.preferences.toolsEnabled },
                set: { newValue in
                    manager.preferences.toolsEnabled = newValue
                    manager.persistPreferences()
                }
            ))
            .toggleStyle(.switch)

            if manager.toolsEnabled {
                Text("**On**: Searxly AI can call the tools you’ve enabled below — research, your own history & bookmarks, reading pages, and more. Tool use is model-driven but heavily constrained by the rules.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("**Off**: No tools are offered to the model. Control is via the chips and very clear imperative sentences (or this toggle).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(AIToolCatalog.byTier, id: \.tier) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.tier.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            ForEach(group.tools) { tool in
                                toolRow(tool)
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 340)

            Text("Turn individual tools on or off in Settings — cloud tools under **Searxly AI**, Web search & Open website under **on-device AI**. All tool activity is logged in AI Activity, and tools only ever use data and services you control.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(20)
        .background(
            (glassEnabled ? .ultraThinMaterial : .regularMaterial),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .frame(minWidth: 470, minHeight: 540)
    }

    @ViewBuilder
    private func toolRow(_ tool: AIToolInfo) -> some View {
        let active = manager.toolsEnabled && manager.isToolEnabled(tool.id)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.icon)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.callout.weight(.semibold))
                    if !tool.availableOnDevice {
                        Text("Cloud")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tool.example)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // Read-only status. The on/off switches live in Settings (cloud tools → Searxly AI tab;
            // Web search & Open website → on-device AI tab).
            Text(active ? "On" : "Off")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(manager.toolsEnabled ? 1 : 0.55)
    }
}

struct CustomInstructionsEditor: View {
    let glassEnabled: Bool
    @Binding var instructions: String
    let onDismiss: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom Instructions for this Chat")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel", action: onDismiss)
                    .glassPill(glassEnabled: glassEnabled)
                    .controlSize(.small)
                Button("Save") {
                    instructions = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDismiss()
                }
                .glassPill(isProminent: true, glassEnabled: glassEnabled)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && instructions.isEmpty)
            }

            Text("These preferences apply only to this chat session and stay entirely on your Mac. They are prepended to the prompt but **core privacy, grounding, and tool rules always take precedence** and cannot be overridden.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.2))
                .padding(.vertical, 4)

            Text("Examples: \"Always be concise and use bullet points\", \"Focus on technical details and cite sources by domain\", \"Remember that I prefer privacy-first options\".")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if !instructions.isEmpty {
                Button("Clear instructions for this chat") {
                    draft = ""
                    instructions = ""
                    onDismiss()
                }
                .font(.caption)
                .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(20)
        .background(
            (glassEnabled ? .ultraThinMaterial : .regularMaterial),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            draft = instructions
        }
    }
}