//
//  AgenticToolsSettingsView.swift
//  Searxly
//
//  Settings pane for Searxly Agentic Tools — the local MCP server that lets a user's OWN local AI
//  call Searxly's private-web tools. Built for non-technical setup: pick your AI app, follow two or
//  three plain steps with a single copy button, then hit "Check connection" for proof it works.
//  Endpoint/key/port live under a collapsed "technical details" area. Everything stays on 127.0.0.1.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgenticToolsSettingsView: View {
    @Bindable private var manager = AgenticServerManager.shared
    private var toolGuard = AgenticToolGuard.shared
    @State private var tokenRevealed = false
    @State private var copiedID: String?
    @State private var selectedClient: ClientApp = .claudeCode
    @State private var showAdvanced = false
    @State private var portText = ""
    @State private var activityFilter: ActivityFilter = .all

    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All", actions = "Actions", blocked = "Blocked", protection = "Protection"
        var id: String { rawValue }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Agentic Tools",
                subtitle: "Let an AI app you run — Claude Code, Claude Desktop, LM Studio, or any app that supports MCP — use Searxly to search and read the web. Everything runs on this Mac; nothing is sent to any AI provider."
            )

            SettingsSection(
                title: "Agentic Tools",
                footer: "Off by default. When on, only apps on this Mac that have your connection details can use the tools."
            ) {
                SettingsToggleRow(
                    title: "Let AI apps use Searxly",
                    description: statusDescription,
                    isOn: $manager.isEnabled,
                    badge: statusBadge?.text,
                    badgeTint: statusBadge?.tint ?? SettingsTheme.textPrimary
                )
            }

            if manager.isEnabled {
                connectSection
                protectionSection
                personalDataSection
                browserControlSection
                toolsSection
                if !manager.recentActivity.isEmpty { activitySection }
                advancedSection
            }
        }
        .onAppear { portText = String(manager.port) }
    }

    // MARK: - Status

    private var statusDescription: String {
        switch manager.status {
        case .stopped:        return "Off — AI apps can't reach Searxly."
        case .starting:       return "Starting…"
        case .running:        return "On — connect your AI app below."
        case .error(let msg): return "Couldn't start: \(msg). Try a different port under technical details."
        }
    }

    private var statusBadge: (text: String, tint: Color)? {
        switch manager.status {
        case .running:  return ("Running", SettingsTheme.green)
        case .error:    return ("Error", SettingsTheme.danger)
        default:        return nil
        }
    }

    // MARK: - Connect your AI app

    private enum ClientApp: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
        case lmStudio = "LM Studio"
        case other = "Other app"
        var id: String { rawValue }
    }

    private struct SetupStep: Identifiable {
        let id = UUID()
        let text: String
        var copyLabel: String? = nil
        var copyValue: String? = nil
        var copyID: String? = nil
    }

    private var connectSection: some View {
        SettingsSection(
            title: "Connect your AI app",
            footer: "Works with any app that supports MCP — the standard way AI apps connect to tools. One-time setup per app."
        ) {
            // Client picker
            HStack(spacing: 8) {
                ForEach(ClientApp.allCases) { client in
                    clientChip(client)
                }
            }

            SettingsInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps(for: selectedClient).enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            stepNumber(index + 1)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(step.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(SettingsTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let label = step.copyLabel, let value = step.copyValue, let copyID = step.copyID {
                                    copyChip(label: label, value: value, id: copyID)
                                }
                            }
                        }
                    }
                }
            }

            if selectedClient == .claudeDesktop {
                clientNote("Claude Desktop's “Add custom connector” only accepts public https web addresses, so it can't use a local connection directly. This route uses its config file with a small bridge (mcp-remote), which needs Node.js (nodejs.org). If you also have Claude Code, that's the simplest option — pick it above.")
            }

            SettingsDivider()

            // Check connection
            HStack(spacing: 10) {
                SettingsActionChip(
                    title: manager.selfTest == .running ? "Checking…" : "Check connection",
                    systemImage: "bolt.horizontal",
                    disabled: !manager.isRunning || manager.selfTest == .running
                ) {
                    manager.runSelfTest()
                }
                .frame(width: 170)

                selfTestResult
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var selfTestResult: some View {
        switch manager.selfTest {
        case .none, .running:
            EmptyView()
        case .ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.green)
                Text("Working — AI apps can connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textPrimary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.warning)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func clientChip(_ client: ClientApp) -> some View {
        let selected = selectedClient == client
        return Button {
            selectedClient = client
        } label: {
            Text(client.rawValue)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    selected ? SettingsTheme.fillStrong : SettingsTheme.fillSubtle,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        selected ? SettingsTheme.hairlineStrong : SettingsTheme.hairline,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func stepNumber(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(SettingsTheme.textPrimary)
            .frame(width: 20, height: 20)
            .background(SettingsTheme.fillStrong, in: Circle())
            .overlay(Circle().strokeBorder(SettingsTheme.hairline, lineWidth: 1))
    }

    /// A subtle, client-specific explanatory note shown under the setup steps.
    private func clientNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textSecondary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyChip(label: String, value: String, id: String) -> some View {
        Button {
            copy(value, id: id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copiedID == id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(copiedID == id ? "Copied" : label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(SettingsTheme.textPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(SettingsTheme.fillSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsTheme.hairlineStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func steps(for client: ClientApp) -> [SetupStep] {
        switch client {
        case .claudeCode:
            return [
                SetupStep(text: "Copy the setup command.",
                          copyLabel: "Copy command", copyValue: claudeCodeCommand, copyID: "cc-cmd"),
                SetupStep(text: "Paste it into Terminal and press Return."),
                SetupStep(text: "Done — ask Claude Code to search the web and it will use Searxly.")
            ]
        case .claudeDesktop:
            return [
                SetupStep(text: "Copy the Claude Desktop configuration.",
                          copyLabel: "Copy configuration", copyValue: claudeDesktopConfigJSON, copyID: "cd-json"),
                SetupStep(text: "In Claude Desktop, open Settings → Developer → Edit Config. Paste this into claude_desktop_config.json and save. If other servers are already listed, add just the \"searxly\" entry."),
                SetupStep(text: "Quit and reopen Claude Desktop. Ask it to search the web and it will use Searxly.")
            ]
        case .lmStudio:
            return [
                SetupStep(text: "Copy the configuration.",
                          copyLabel: "Copy configuration", copyValue: mcpConfigJSON, copyID: "lm-json"),
                SetupStep(text: "In LM Studio, open the Program panel (the >_ icon on the right) and choose Install → Edit mcp.json."),
                SetupStep(text: "Paste the configuration into that file and save. If other servers are already listed, add just the \"searxly\" entry.")
            ]
        case .other:
            return [
                SetupStep(text: "If your app asks for a URL or link, use your connection link.",
                          copyLabel: "Copy link", copyValue: manager.connectionLink, copyID: "ot-link"),
                SetupStep(text: "If your app uses a configuration file (often called mcp.json), use this instead.",
                          copyLabel: "Copy configuration", copyValue: mcpConfigJSON, copyID: "ot-json"),
                SetupStep(text: "Look for \"MCP\", \"Connectors\", or \"Tools\" in your app's settings — that's where it goes.")
            ]
        }
    }

    // MARK: - Protection (Bulwark tool-call guard)

    private var protectionSection: some View {
        SettingsSection(
            title: "Protection",
            footer: "Powered by Bulwark, Searxly's open-source safeguard. Web content handed to your AI is checked for hidden instructions, links shaped like data theft are refused, and runaway call loops are stopped."
        ) {
            if toolGuard.actionsHalted {
                let userPaused = toolGuard.manualPause && !toolGuard.actionsPaused
                SettingsCallout(
                    title: userPaused ? "Actions paused by you" : "Actions paused",
                    message: userPaused
                        ? "You paused all acting tools. Your AI can still search and read, but can't click, type, open tabs, or save bookmarks until you resume."
                        : "A page returned by \(protectionSourceName) contained text that tries to give your AI instructions. Tools that act — clicking, typing, opening tabs, saving bookmarks — are paused. Searching and reading still work. Resume when you've had a look at what your AI was doing.",
                    tint: SettingsTheme.warning,
                    systemImage: "shield.lefthalf.filled"
                )
                HStack {
                    SettingsActionChip(title: "Resume actions", systemImage: "play.fill") {
                        toolGuard.resumeActions()
                    }
                    .frame(width: 170)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.green)
                    Text(toolGuard.blockedCallCount == 0
                         ? "Active — nothing suspicious this session."
                         : "Active — \(toolGuard.blockedCallCount) risky call\(toolGuard.blockedCallCount == 1 ? "" : "s") blocked this session.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    Spacer(minLength: 0)
                    SettingsActionChip(title: "Pause all actions", systemImage: "pause.fill") {
                        toolGuard.setManualPause(true)
                    }
                    .frame(width: 160)
                }
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Redact personal info from results",
                description: manager.redactPIIEnabled
                    ? "On — emails, phone numbers, card numbers, national IDs, names, and addresses in tool results are replaced with placeholders before your AI sees them. Links and city/region are kept so tools stay useful. Best when your AI is a cloud model."
                    : "Off — tool results reach your AI as-is. Fine when your AI runs fully on this Mac; leave on if it might be a cloud model.",
                isOn: $manager.redactPIIEnabled
            )
        }
    }

    private var protectionSourceName: String {
        toolGuard.pauseSourceTool.map { displayName(for: $0) } ?? "a web tool"
    }

    // MARK: - Personal data

    private var personalDataSection: some View {
        SettingsSection(
            title: "Personal data",
            footer: "Lets your AI search your browsing history and bookmarks, and save new bookmarks — so it can answer things like \"find that article I read last week\". Off by default; your data never leaves this Mac either way."
        ) {
            SettingsToggleRow(
                title: "Allow access to history & bookmarks",
                description: manager.personalDataEnabled
                    ? "On — your AI can search your history and bookmarks and save bookmarks for you."
                    : "Off — your history and bookmarks are invisible to your AI.",
                isOn: $manager.personalDataEnabled
            )
        }
    }

    // MARK: - Browser control

    private var browserControlSection: some View {
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

            if manager.browserControlEnabled {
                SettingsDivider()
                SettingsToggleRow(
                    title: "Ask before submitting forms",
                    description: manager.confirmActionsEnabled
                        ? "On — your AI can fill fields on its own, but submitting a form (posting data, creating an account, sending a message) waits for your one-tap approval."
                        : "Off — your AI can submit forms without asking.",
                    isOn: $manager.confirmActionsEnabled
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Isolate agent in a logged-out tab",
                    description: manager.agentIsolatedContext
                        ? "On — browser actions run in a separate private tab with no access to your logins or cookies, so your AI can't act as the signed-in you."
                        : "Off — your AI acts on your real active tab, including sites you're signed in to.",
                    isOn: $manager.agentIsolatedContext
                )
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        SettingsSection(
            title: "Tools",
            footer: "Turn a tool off to stop your AI from using it. Personal-data and browser-control tools appear here only while their toggles above are on."
        ) {
            let tools = AgenticToolRegistry.shared.tools.filter {
                (!$0.requiresBrowserControl || manager.browserControlEnabled)
                    && (!$0.requiresPersonalData || manager.personalDataEnabled)
            }
            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                if index > 0 { SettingsDivider() }
                SettingsToggleRow(
                    title: tool.title,
                    description: tool.summary,
                    isOn: Binding(
                        get: { manager.isToolEnabled(tool.id) },
                        set: { manager.setTool(tool.id, enabled: $0) }
                    )
                )
            }
        }
    }

    // MARK: - Recent activity

    private var filteredActivity: [AgenticServerManager.ActivityEntry] {
        switch activityFilter {
        case .all:        return manager.recentActivity
        case .actions:    return manager.recentActivity.filter { $0.tool != "protection" }
        case .blocked:    return manager.recentActivity.filter { !$0.ok }
        case .protection: return manager.recentActivity.filter { $0.tool == "protection" }
        }
    }

    private func activityFilterChip(_ f: ActivityFilter) -> some View {
        let selected = activityFilter == f
        return Button { activityFilter = f } label: {
            Text(f.rawValue)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? SettingsTheme.fillStrong : SettingsTheme.fillSubtle, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? SettingsTheme.hairlineStrong : SettingsTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func activityIcon(_ e: AgenticServerManager.ActivityEntry) -> (name: String, color: Color) {
        if e.tool == "protection" {
            return (e.ok ? "shield.lefthalf.filled" : "shield.slash", e.ok ? SettingsTheme.green : SettingsTheme.warning)
        }
        return e.ok ? ("checkmark.circle", SettingsTheme.textSecondary) : ("exclamationmark.triangle.fill", SettingsTheme.warning)
    }

    private var activitySection: some View {
        SettingsSection(
            title: "Recent activity",
            footer: "The tool calls your AI has made — labels and short argument summaries only, never full content. Filter, export a copy for your records, or keep the log across launches."
        ) {
            HStack(spacing: 7) {
                ForEach(ActivityFilter.allCases) { activityFilterChip($0) }
                Spacer(minLength: 0)
            }
            SettingsDivider()

            let entries = Array(filteredActivity.prefix(12))
            if entries.isEmpty {
                Text("No matching activity yet.")
                    .font(.caption)
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else {
                ForEach(entries) { entry in
                    let icon = activityIcon(entry)
                    HStack(spacing: 8) {
                        Image(systemName: icon.name).foregroundStyle(icon.color).font(.caption)
                        Text(displayName(for: entry.tool)).font(.subheadline.weight(.medium))
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                    }
                    .padding(.vertical, 1)
                }
            }

            SettingsDivider()
            HStack {
                SettingsActionChip(title: "Export…", systemImage: "square.and.arrow.up") { exportActivity() }
                    .frame(width: 130)
                Spacer(minLength: 0)
                Text("\(manager.recentActivity.count) recorded this session")
                    .font(.caption2)
                    .foregroundStyle(SettingsTheme.textTertiary)
            }

            if !Edition.isMaximum {
                SettingsDivider()
                SettingsToggleRow(
                    title: "Keep this log across launches",
                    description: manager.persistActivityLog
                        ? "On — recent activity is saved on this Mac and restored when you reopen Searxly."
                        : "Off — the log stays in memory only and clears when you quit.",
                    isOn: $manager.persistActivityLog
                )
            }
        }
    }

    private func exportActivity() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "searxly-agentic-activity.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? manager.exportActivityText().data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func displayName(for toolID: String) -> String {
        if toolID == "protection" { return "Protection" }
        return AgenticToolRegistry.shared.tools.first(where: { $0.id == toolID })?.title ?? toolID
    }

    // MARK: - Advanced (collapsed technical details)

    private var advancedSection: some View {
        SettingsSection(
            title: "Advanced",
            footer: showAdvanced ? "Only needed for custom setups. Getting a new key signs out every app you've already connected." : nil
        ) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text(showAdvanced ? "Hide technical details" : "Show technical details")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SettingsTheme.textTertiary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                SettingsDivider()
                copyRow(label: "Endpoint", shown: manager.endpointURL, copyValue: manager.endpointURL, id: "endpoint")
                SettingsDivider()
                copyRow(label: "Access key",
                        shown: tokenRevealed ? manager.authToken : String(repeating: "•", count: 24),
                        copyValue: manager.authToken, id: "token", secret: true)
                SettingsDivider()
                copyRow(label: "Link + key", shown: manager.connectionLink, copyValue: manager.connectionLink, id: "link")
                SettingsDivider()

                SettingsLabeledField(
                    title: "Port",
                    description: "1025–65535. The server restarts on the new port; reconnect your apps after changing it."
                ) {
                    HStack(spacing: 8) {
                        TextField(String(AgenticServerManager.defaultPort), text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                        SettingsActionChip(title: "Apply", disabled: portText == String(manager.port)) { applyPort() }
                            .frame(width: 80)
                    }
                }

                SettingsDivider()
                HStack(spacing: 12) {
                    Button(copiedID == "config" ? "Copied ✓" : "Copy MCP config") { copy(mcpConfigJSON, id: "config") }
                    Spacer()
                    Button("Get a new key") { manager.rotateToken(); tokenRevealed = false }
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.top, 2)
            }
        }
    }

    private func applyPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 1024 else {
            portText = String(manager.port)   // revert invalid input
            return
        }
        manager.port = value
    }

    // MARK: - Shared rows + helpers

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

    /// One-line Claude Code setup — registers Searxly as a user-scoped MCP server.
    private var claudeCodeCommand: String {
        "claude mcp add --transport http searxly \"\(manager.endpointURL)\" --header \"Authorization: Bearer \(manager.authToken)\""
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

    /// Claude Desktop config snippet. Claude Desktop's "Add custom connector" only accepts public https
    /// web addresses, so it can't reach Searxly's local http loopback endpoint directly. Instead we go
    /// through its config file with `mcp-remote`, a tiny stdio↔HTTP bridge (needs Node.js). Notes:
    ///   • `--allow-http` permits the plain-http loopback endpoint (fine here — traffic never leaves the Mac).
    ///   • The header arg is written WITHOUT a space (`Authorization:${SEARXLY_AUTH}`) and the real value
    ///     ("Bearer <token>") lives in `env`, dodging a known mcp-remote/npx bug that mangles spaces inside args.
    private var claudeDesktopConfigJSON: String {
        """
        {
          "mcpServers": {
            "searxly": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote",
                "\(manager.endpointURL)",
                "--allow-http",
                "--header",
                "Authorization:${SEARXLY_AUTH}"
              ],
              "env": {
                "SEARXLY_AUTH": "Bearer \(manager.authToken)"
              }
            }
          }
        }
        """
    }
}
