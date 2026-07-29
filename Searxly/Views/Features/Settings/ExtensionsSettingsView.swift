//
//  ExtensionsSettingsView.swift
//  Searxly
//
//  Lane B — the userscript authoring + management UI (Phase 2). Built entirely from the Settings design
//  primitives (SettingsLayout.swift) so it stays monochrome and on-brand. Manual authoring only here;
//  AI generation is Phase 3 (it will produce a UserScript through the very same editor + validator path).
//
//  See Extensions/EXTENSION_IMPLEMENTATION_NOTES.md.
//

import SwiftUI

struct ExtensionsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scripts: [UserScript] = []
    @State private var masterEnabled: Bool = UserScriptManager.shared.isEnabled
    @State private var editingDraft: EditableScript?
    @State private var scriptPendingDelete: UserScript?

    // Lane A (real WebExtensions) — bring-up controls, Dev-Mode only.
    @State private var spikeReport: String?
    @State private var spikeRunning = false
    @State private var laneAEnabled = ExtensionFeatures.laneAEnabled
    @State private var managerStatus: String?
    @State private var laneAExtensions: [LaneAExtensionSnapshot] = []
    @State private var storeStatus: String?

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Extensions",
                subtitle: "Browser extensions, plus your own userscripts. Extensions run only with the access you grant; userscripts run only on the sites you scope them to."
            )

            SettingsSection(title: "Userscripts") {
                SettingsToggleRow(
                    title: "Enable userscripts",
                    description: "Master switch. When off, no userscript runs anywhere.",
                    isOn: Binding(
                        get: { masterEnabled },
                        set: { newValue in
                            masterEnabled = newValue
                            UserScriptManager.shared.setGloballyEnabled(newValue)
                        }
                    )
                )
            }

            SettingsCallout(
                title: "How userscripts stay safe",
                message: "Userscripts run in an isolated sandbox with no network access and no reach into Searxly itself. They never run in Private or Tor tabs, and you review every line before enabling one.",
                tint: .secondary,
                systemImage: "checkmark.shield.fill"
            )

            SettingsSection(title: "Installed", footer: footerText) {
                if scripts.isEmpty {
                    emptyState
                } else {
                    ForEach(scripts) { script in
                        ExtensionScriptRow(
                            script: script,
                            isEnabledBinding: Binding(
                                get: { script.isEnabled },
                                set: { newValue in
                                    UserScriptManager.shared.setEnabled(newValue, for: script.id)
                                    refresh()
                                }
                            ),
                            onEdit: { editingDraft = EditableScript(from: script) },
                            onDelete: { scriptPendingDelete = script }
                        )
                        if script.id != scripts.last?.id {
                            SettingsDivider()
                        }
                    }
                }
            }

            SettingsProminentAction(
                title: "New userscript",
                systemImage: "plus"
            ) {
                editingDraft = EditableScript.blank()
            }

            extensionsStoreSection

            if DeveloperSettings.shared.isEnabled {
                developerSection
            }
        }
        .onAppear(perform: refresh)
        .sheet(item: $editingDraft) { draft in
            ExtensionEditorSheet(
                draft: draft,
                onSave: { updated in
                    UserScriptManager.shared.upsert(updated.toUserScript())
                    editingDraft = nil
                    refresh()
                },
                onCancel: { editingDraft = nil }
            )
        }
        .confirmationDialog(
            "Delete this userscript?",
            isPresented: Binding(get: { scriptPendingDelete != nil }, set: { if !$0 { scriptPendingDelete = nil } }),
            presenting: scriptPendingDelete
        ) { script in
            Button("Delete \"\(script.name)\"", role: .destructive) {
                UserScriptManager.shared.remove(id: script.id)
                scriptPendingDelete = nil
                refresh()
            }
            Button("Cancel", role: .cancel) { scriptPendingDelete = nil }
        }
    }

    private var footerText: String {
        let enabled = scripts.filter { $0.isEnabled }.count
        if scripts.isEmpty { return "Changes apply to new tabs immediately, and to open tabs after a reload." }
        return "\(enabled) of \(scripts.count) enabled. Changes apply to new tabs immediately, and to open tabs after a reload."
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No userscripts yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
            Text("Create one with “New userscript” below.")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() {
        scripts = UserScriptManager.shared.scripts.sorted { $0.createdAt > $1.createdAt }
        masterEnabled = UserScriptManager.shared.isEnabled
        // Lane A installed list. Only query when the user actually has extensions (or the engine is on /
        // Dev mode), so the controller isn't instantiated for users who never touch extensions.
        if #available(macOS 15.4, *),
           ExtensionInstallStore.hasInstalled() || ExtensionFeatures.laneAEnabled || DeveloperSettings.shared.isEnabled {
            laneAExtensions = ExtensionManager.shared.snapshots()
        }
    }

    private func openChromeWebStore() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(
                name: .openURLInNewTab,
                object: ChromeWebStore.storeHomeURL,
                userInfo: ["background": false]
            )
        }
    }

    // MARK: - Developer: Lane A engine spike

    @ViewBuilder private var developerSection: some View {
        SettingsSection(
            title: "Developer · Lane A",
            footer: "Real WebExtensions (the curated gallery) are in early bring-up. This runs the Phase 0 engine spike: it loads a throwaway extension and checks a content script runs."
        ) {
            if #available(macOS 15.4, *) {
                SettingsToggleRow(
                    title: "Enable Lane A engine (flag)",
                    description: "Attaches the WebExtension controller to standard tabs. Off by default during bring-up; affects new tabs.",
                    isOn: Binding(
                        get: { laneAEnabled },
                        set: { newValue in
                            laneAEnabled = newValue
                            ExtensionFeatures.laneAEnabled = newValue
                        }
                    )
                )

                SettingsActionChipGrid {
                    SettingsActionChip(
                        title: spikeRunning ? "Running…" : "Run engine spike",
                        systemImage: "ant.fill",
                        disabled: spikeRunning
                    ) { runSpike() }

                    SettingsActionChip(
                        title: "Load test extension",
                        systemImage: "shippingbox"
                    ) { loadTestExtension() }
                }

                if let managerStatus {
                    Text(managerStatus)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let spikeReport {
                    Text(spikeReport)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            } else {
                SettingsCallout(
                    title: "Requires macOS 15.4",
                    message: "The WebExtension engine needs macOS 15.4 or later. Lane B userscripts above work on macOS 15.0.",
                    tint: .secondary,
                    systemImage: "info.circle.fill"
                )
            }
        }
    }

    private func runSpike() {
        guard #available(macOS 15.4, *) else { return }
        spikeRunning = true
        spikeReport = "Running spike…"
        Task {
            let report = await WebExtensionSpike().run()
            spikeReport = report.text
            spikeRunning = false
        }
    }

    private func loadTestExtension() {
        guard #available(macOS 15.4, *) else { return }
        managerStatus = "Loading…"
        Task {
            do {
                let dir = try WebExtensionSpike.writeTestExtension()
                let entry = try await ExtensionManager.shared.load(directory: dir, grantRequestedHosts: true)
                managerStatus = "Loaded \"\(entry.displayName)\" — granted "
                    + "\(entry.grantedHostCount)/\(entry.requestedHosts.count) host pattern(s), default-deny otherwise. "
                    + "Turn the flag on, open a NEW standard tab, and browse — the content script "
                    + "prepends “SPIKE-OK ” to the page title."
            } catch {
                managerStatus = "Load failed: \(error.localizedDescription)"
            }
            refreshLaneA()
        }
    }

    private func refreshLaneA() {
        guard #available(macOS 15.4, *) else { return }
        laneAExtensions = ExtensionManager.shared.snapshots()
    }

    private func grantLaneA(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.grantRequestedHosts(forLoadedID: id)
        refreshLaneA()
    }

    private func revokeLaneA(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.revokeAll(forLoadedID: id)
        refreshLaneA()
    }

    // MARK: - Browser extensions store (Lane A, normal-user)

    @ViewBuilder private var extensionsStoreSection: some View {
        SettingsSection(
            title: "Browser extensions",
            footer: "Add extensions straight from the Chrome Web Store. Each runs only with the access you grant, and never in Private or Tor tabs."
        ) {
            if #available(macOS 15.4, *) {
                if laneAExtensions.isEmpty {
                    extensionsEmptyState
                } else {
                    ForEach(laneAExtensions) { ext in
                        installedExtensionCard(ext)
                    }
                }

                if let storeStatus {
                    Text(storeStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SettingsCallout(
                    title: "Requires macOS 15.4",
                    message: "Browser extensions need macOS 15.4 or later. The userscripts above work on macOS 15.0.",
                    tint: .secondary,
                    systemImage: "info.circle.fill"
                )
            }
        }

        if #available(macOS 15.4, *) {
            SettingsProminentAction(
                title: "Get extensions from the Chrome Web Store",
                systemImage: "puzzlepiece.extension.fill"
            ) {
                openChromeWebStore()
            }
        }
    }

    private var extensionsEmptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No extensions installed")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsTheme.textPrimary)
            Text("Browse the Chrome Web Store below and click “Add to Searxly” on any extension’s page.")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func installedExtensionCard(_ ext: LaneAExtensionSnapshot) -> some View {
        SettingsInsetPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    extensionIcon(ext)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        statusLine(ext)
                    }
                    Spacer(minLength: 0)
                    SettingsActionChip(title: "Remove", systemImage: "trash", role: .destructive) { uninstallExtension(ext.id) }
                        .frame(maxWidth: 108)
                }

                if let warning = ext.healthWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !ext.requestedHosts.isEmpty {
                    Text("Runs on: " + ext.requestedHosts.joined(separator: "  "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SettingsTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if ext.grantedHostCount > 0 {
                        SettingsActionChip(title: "Pause everywhere", systemImage: "pause.circle") { revokeLaneA(ext.id) }
                            .frame(maxWidth: 160)
                    } else {
                        SettingsActionChip(title: "Turn on", systemImage: "play.circle") { grantLaneA(ext.id) }
                            .frame(maxWidth: 130)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private func extensionIcon(_ ext: LaneAExtensionSnapshot) -> some View {
        if let icon = ext.icon {
            Image(nsImage: icon)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13))
                .foregroundStyle(SettingsTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(SettingsTheme.fillSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder private func statusLine(_ ext: LaneAExtensionSnapshot) -> some View {
        if ext.healthWarning != nil {
            Text("Limited — engine errors")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.warning)
        } else if ext.grantedHostCount > 0 {
            Text("On")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.green)
        } else {
            Text("Off — no site access")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.textSecondary)
        }
    }

    private func uninstallExtension(_ id: UUID) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionManager.shared.uninstall(loadedID: id)
        laneAEnabled = ExtensionFeatures.laneAEnabled
        storeStatus = "Removed."
        refreshLaneA()
    }
}

// MARK: - Script row

private struct ExtensionScriptRow: View {
    let script: UserScript
    @Binding var isEnabledBinding: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var validation: UserScriptValidation { UserScriptValidator.validate(script) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(script.name.isEmpty ? "Untitled" : script.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .lineLimit(1)

                authorBadge
                statusBadge

                Spacer(minLength: 8)

                Toggle("", isOn: $isEnabledBinding)
                    .labelsHidden()
            }

            Text(patternSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                SettingsActionChip(title: "Edit", systemImage: "pencil", action: onEdit)
                    .frame(maxWidth: 120)
                SettingsActionChip(title: "Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .frame(maxWidth: 120)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var authorBadge: some View {
        switch script.author {
        case .manual: SettingsBadge(text: "Manual", tint: .secondary)
        case .ai:     SettingsBadge(text: "AI", tint: .secondary)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if script.isEnabled {
            if validation.isValid {
                SettingsBadge(text: "On", tint: SettingsTheme.green)
            } else {
                SettingsBadge(text: "Won't run", tint: SettingsTheme.danger)
            }
        } else {
            SettingsBadge(text: "Off", tint: .secondary)
        }
    }

    private var patternSummary: String {
        guard let first = script.matchPatterns.first else { return "No sites scoped" }
        let extra = script.matchPatterns.count - 1
        return extra > 0 ? "\(first)  +\(extra) more" : first
    }
}

// MARK: - Editable draft

private struct EditableScript: Identifiable {
    let id: UUID
    var isNew: Bool
    var name: String
    var patternsText: String
    var body: String
    var runAt: UserScript.RunAt
    var isEnabled: Bool
    var author: UserScript.Author
    var createdAt: Date
    var prompt: String?

    static func blank() -> EditableScript {
        EditableScript(
            id: UUID(), isNew: true, name: "", patternsText: "",
            body: "// Runs on the sites you scope above.\n",
            runAt: .documentEnd, isEnabled: true, author: .manual, createdAt: Date(), prompt: nil
        )
    }

    init(id: UUID, isNew: Bool, name: String, patternsText: String, body: String, runAt: UserScript.RunAt, isEnabled: Bool, author: UserScript.Author, createdAt: Date, prompt: String?) {
        self.id = id; self.isNew = isNew; self.name = name; self.patternsText = patternsText
        self.body = body; self.runAt = runAt; self.isEnabled = isEnabled; self.author = author
        self.createdAt = createdAt; self.prompt = prompt
    }

    init(from s: UserScript) {
        id = s.id; isNew = false; name = s.name
        patternsText = s.matchPatterns.joined(separator: "\n")
        body = s.body; runAt = s.runAt; isEnabled = s.isEnabled; author = s.author
        createdAt = s.createdAt; prompt = s.prompt
    }

    var parsedPatterns: [String] {
        patternsText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func toUserScript() -> UserScript {
        UserScript(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            matchPatterns: parsedPatterns,
            body: body,
            isEnabled: isEnabled,
            runAt: runAt,
            author: author,
            createdAt: createdAt,
            prompt: prompt
        )
    }
}

// MARK: - Editor sheet

private struct ExtensionEditorSheet: View {
    @State var draft: EditableScript
    let onSave: (EditableScript) -> Void
    let onCancel: () -> Void

    private var liveValidation: UserScriptValidation {
        UserScriptValidator.validate(draft.toUserScript())
    }

    private var bodyOverLimit: Bool { draft.body.count > UserScriptLimits.maxBodyChars }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SettingsTheme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsLabeledField(title: "Name") {
                        TextField("e.g. Tidy YouTube", text: $draft.name)
                            .textFieldStyle(.plain)
                            .foregroundStyle(SettingsTheme.textPrimary)
                            .modifier(DarkField())
                    }

                    SettingsLabeledField(
                        title: "Runs on these sites",
                        description: "One match pattern per line. Examples: *://*.youtube.com/*  ·  https://example.com/*  ·  <all_urls>"
                    ) {
                        TextEditor(text: $draft.patternsText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SettingsTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 64)
                            .modifier(DarkField())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run timing")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        Picker("", selection: $draft.runAt) {
                            Text("Page start").tag(UserScript.RunAt.documentStart)
                            Text("Page loaded").tag(UserScript.RunAt.documentEnd)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .tint(SettingsTheme.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Script")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SettingsTheme.textPrimary)
                            Spacer()
                            Text("\(draft.body.count) / \(UserScriptLimits.maxBodyChars)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(bodyOverLimit ? SettingsTheme.danger : SettingsTheme.textTertiary)
                        }
                        TextEditor(text: $draft.body)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SettingsTheme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 200)
                            .modifier(DarkField())
                    }

                    validationView
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 640)
        .background(SettingsTheme.canvas)
        .toggleStyle(PremiumToggleStyle())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(draft.isNew ? "New userscript" : "Edit userscript")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsTheme.textPrimary)
            Spacer()
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(SettingsTheme.fillSubtle, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button { onSave(draft) } label: {
                Text("Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.onInk)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(SettingsTheme.inkFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(SettingsTheme.canvasRaised)
    }

    @ViewBuilder private var validationView: some View {
        switch liveValidation {
        case .valid:
            SettingsCallout(
                title: "Looks good",
                message: draft.isEnabled
                    ? "This script passes validation and will run on the scoped sites."
                    : "This script passes validation. Enable it in the list to run it.",
                tint: SettingsTheme.green,
                systemImage: "checkmark.circle.fill"
            )
        case .invalid(let reasons):
            VStack(alignment: .leading, spacing: 8) {
                SettingsCallout(
                    title: "Needs changes before it can run",
                    message: "You can still save a draft, but it won't run until these are fixed:",
                    tint: SettingsTheme.danger,
                    systemImage: "exclamationmark.triangle.fill"
                )
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 7) {
                            Text("•").foregroundStyle(SettingsTheme.danger)
                            Text(reason)
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - Field styling

private struct DarkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SettingsTheme.fillSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
            )
    }
}
