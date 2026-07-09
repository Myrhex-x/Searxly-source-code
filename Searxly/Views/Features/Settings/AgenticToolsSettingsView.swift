//
//  AgenticToolsSettingsView.swift
//  Searxly
//
//  Settings pane for Searxly Agentic Tools — the local MCP server that lets a user's OWN local AI
//  call Searxly's private-web tools. Deliberately minimal: enable the server, copy the connection
//  details into an MCP client, toggle individual tools. Everything stays on 127.0.0.1.
//

import SwiftUI
import AppKit

struct AgenticToolsSettingsView: View {
    @Bindable private var manager = AgenticServerManager.shared
    @State private var tokenRevealed = false
    @State private var copiedID: String?

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Agentic Tools",
                subtitle: "Let your own local AI call Searxly's private-web tools. Everything runs on your Mac — nothing is sent to any AI provider."
            )

            SettingsSection(
                title: "Local MCP server",
                footer: "Exposes Searxly's tools over the Model Context Protocol on 127.0.0.1 only. Point any MCP client (Ollama-based agents, LM Studio, Claude Desktop, …) at the endpoint below. Off by default."
            ) {
                SettingsToggleRow(
                    title: "Enable Agentic Tools",
                    description: statusDescription,
                    isOn: $manager.isEnabled
                )
            }

            if manager.isEnabled {
                SettingsSection(
                    title: "Connection",
                    footer: "Paste these into your MCP client. Keep the token private — it's the key that lets a client use your tools."
                ) {
                    copyRow(label: "Endpoint", shown: manager.endpointURL, copyValue: manager.endpointURL, id: "endpoint")
                    SettingsDivider()
                    copyRow(label: "Token",
                            shown: tokenRevealed ? manager.authToken : String(repeating: "•", count: 24),
                            copyValue: manager.authToken, id: "token", secret: true)
                    SettingsDivider()
                    HStack(spacing: 12) {
                        Button(copiedID == "config" ? "Copied ✓" : "Copy MCP config") { copy(mcpConfigJSON, id: "config") }
                        Spacer()
                        Button("Rotate token") { manager.rotateToken(); tokenRevealed = false }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.top, 2)
                }

                SettingsSection(
                    title: "Browser control",
                    footer: "Lets your AI act on your REAL active tab — snapshot the page, then click, type, and navigate. Powerful: it can change what you see and interact with logged-in sites. Off by default; the read-only web tools work without it."
                ) {
                    SettingsToggleRow(
                        title: "Allow browser control",
                        description: manager.browserControlEnabled
                            ? "On — page snapshot, click, type, navigate, and screenshot tools are available to your AI."
                            : "Off — only the read-only web tools (search, read page, knowledge) are exposed.",
                        isOn: $manager.browserControlEnabled
                    )
                }

                SettingsSection(
                    title: "Tools",
                    footer: "Turn a tool off to stop your AI from using it. Browser-control tools appear here only while the toggle above is on."
                ) {
                    let tools = AgenticToolRegistry.shared.tools.filter { !$0.requiresBrowserControl || manager.browserControlEnabled }
                    ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                        if index > 0 { SettingsDivider() }
                        SettingsToggleRow(
                            title: tool.id,
                            description: tool.summary,
                            isOn: Binding(
                                get: { manager.isToolEnabled(tool.id) },
                                set: { manager.setTool(tool.id, enabled: $0) }
                            )
                        )
                    }
                }

                if !manager.recentActivity.isEmpty {
                    SettingsSection(
                        title: "Recent activity",
                        footer: "The tool calls your AI has made this session (kept in memory only)."
                    ) {
                        ForEach(manager.recentActivity.prefix(10)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(entry.ok ? Color.secondary : Color.orange)
                                    .font(.caption)
                                Text(entry.tool).font(.subheadline.weight(.medium))
                                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
    }

    private var statusDescription: String {
        switch manager.status {
        case .stopped:        return "Off. Your local AI can't reach Searxly's tools."
        case .starting:       return "Starting…"
        case .running:        return "Running at \(manager.endpointURL) — your local AI can call the tools below."
        case .error(let msg): return "Couldn't start: \(msg)"
        }
    }

    @ViewBuilder
    private func copyRow(label: String, shown: String, copyValue: String, id: String, secret: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).frame(width: 72, alignment: .leading)
            Text(shown)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if secret {
                Button(tokenRevealed ? "Hide" : "Reveal") { tokenRevealed.toggle() }.font(.caption)
            }
            Button(copiedID == id ? "Copied ✓" : "Copy") { copy(copyValue, id: id) }.font(.caption)
        }
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { copiedID = nil }
        }
    }

    /// A standard MCP client config snippet (Streamable HTTP + bearer token).
    private var mcpConfigJSON: String {
        """
        {
          "mcpServers": {
            "searxly": {
              "url": "\(manager.endpointURL)",
              "headers": { "Authorization": "Bearer \(manager.authToken)" }
            }
          }
        }
        """
    }
}
