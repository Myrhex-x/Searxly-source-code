//
//  InstancesSettingsView.swift
//  Searxly
//

import SwiftUI

struct InstancesSettingsView: View {
    @Binding var searxInstances: [SearXNGInstance]
    @Binding var currentInstanceID: UUID

    @State private var newInstanceName: String = ""
    @State private var newInstanceURL: String = ""
    @State private var manualLocalURL: String = ""
    @State private var showSetupLogs = false
    @State private var showLANExposureWarning = false
    @State private var showAdvanced = false
    @State private var developerLANExposureEnabled = false

    private var manager: LocalSearxngManager { LocalSearxngManager.shared }

    private var activeInstance: SearXNGInstance? {
        searxInstances.first { $0.id == currentInstanceID }
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "SearXNG Instances",
                subtitle: "Choose where searches run. Searxly only connects to instances you configure here."
            )

            activeInstanceSection

            SettingsSection(
                title: "Local search on this Mac",
                footer: "Runs a private SearXNG built into Searxly — nothing to install. Recommended for keeping queries on your computer."
            ) {
                localSearchPanel
            }

            SettingsSection(
                title: "Your instances",
                footer: searxInstances.isEmpty
                    ? "Add a local or remote instance below."
                    : "Tap Use to switch the active search backend."
            ) {
                if searxInstances.isEmpty {
                    emptyInstancesState
                } else {
                    ForEach(Array(searxInstances.enumerated()), id: \.element.id) { index, inst in
                        instanceCard(inst)
                        if index < searxInstances.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }

            SettingsSection(
                title: "Add remote instance",
                footer: "A SearXNG server you host elsewhere. HTTPS is strongly recommended."
            ) {
                SettingsLabeledField(title: "Display name") {
                    TextField("My server", text: $newInstanceName)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsLabeledField(
                    title: "Instance URL",
                    description: "Base URL without a path, e.g. https://search.example.com"
                ) {
                    TextField("https://search.example.com", text: $newInstanceURL)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    addNewInstance()
                } label: {
                    Label("Add instance", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(
                    newInstanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .sheet(isPresented: $showSetupLogs) {
            setupLogsSheet
        }
        .alert("Expose SearXNG on your network?", isPresented: $showLANExposureWarning) {
            Button("Cancel", role: .cancel) {
                developerLANExposureEnabled = false
            }
            Button("Expose on LAN", role: .destructive) {
                developerLANExposureEnabled = true
                manager.bindToLocalhostOnly = false
                Task { await manager.restart() }
            }
        } message: {
            Text("Other devices on your Wi‑Fi or Ethernet could reach your SearXNG instance and run searches through it. Only enable this if you understand the risk.")
        }
    }

    // MARK: - Active instance

    @ViewBuilder
    private var activeInstanceSection: some View {
        if let active = activeInstance {
            SettingsSection(title: "Active for search") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: isLocalURL(active.url) ? "desktopcomputer" : "globe")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(active.name)
                            .font(.headline)
                        Text(active.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    SettingsBadge(
                        text: isLocalURL(active.url) ? "Local" : "Remote",
                        tint: isLocalURL(active.url) ? .green : .blue
                    )
                }
            }
        }
    }

    // MARK: - Local SearXNG

    private var localSearchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsInsetPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: statusSystemImage(for: manager.status))
                            .font(.title2)
                            .foregroundStyle(statusColor(for: manager.status))
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(statusTitle(for: manager.status))
                                    .font(.subheadline.weight(.semibold))
                                SettingsBadge(
                                    text: statusBadge(for: manager.status),
                                    tint: statusColor(for: manager.status)
                                )
                            }
                            Text(statusDescription(for: manager.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if manager.isBusy || manager.status == .starting || manager.status == .stopping {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("This Mac only — not shared with other devices on your network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if manager.bindToLocalhostOnly {
                            SettingsBadge(text: "Protected", tint: .green)
                        } else {
                            SettingsBadge(text: "LAN", tint: .orange)
                        }
                    }

                    if let error = manager.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            localPrimaryControl

            if hasLocalSecondaryActions {
                localSecondaryActions
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedLocalOptions
            }
            .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private var localPrimaryControl: some View {
        if needsFullSetup {
            SettingsProminentAction(
                title: manager.isBusy ? "Setting up local search…" : "Set up local search",
                systemImage: "sparkles",
                action: { Task { await manager.ensureReadyAndRunning() } }
            )
            .disabled(manager.isBusy)

            Text("SearXNG is built in — nothing to install. First launch takes a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if manager.status == .stopped {
            SettingsProminentAction(
                title: manager.isBusy ? "Starting…" : "Start local search",
                systemImage: "play.fill",
                action: { Task { await manager.start() } }
            )
            .disabled(manager.isBusy)
        } else if manager.status == .running {
            SettingsProminentAction(
                title: manager.isBusy ? "Stopping…" : "Stop local search",
                systemImage: "stop.fill",
                tint: .red,
                action: { Task { await manager.stop() } }
            )
            .disabled(manager.isBusy)
        }
    }

    private var hasLocalSecondaryActions: Bool {
        manager.status == .running
            || !manager.logs.isEmpty
    }

    @ViewBuilder
    private var localSecondaryActions: some View {
        SettingsActionChipGrid {
            if manager.status == .running, !isLocalInstanceActive {
                SettingsActionChip(title: "Use for search", systemImage: "checkmark.circle") {
                    activateLocalInstance()
                }
            }

            if manager.status == .running {
                SettingsActionChip(title: "Restart", systemImage: "arrow.clockwise") {
                    Task { await manager.restart() }
                }
                .disabled(manager.isBusy)
            }

            if !manager.logs.isEmpty {
                SettingsActionChip(title: "View log", systemImage: "doc.text") {
                    showSetupLogs = true
                }
            }
        }
    }

    @ViewBuilder
    private var advancedLocalOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.canConfigureLANExposure {
                SettingsToggleRow(
                    title: "Expose on local network",
                    description: "Developer option. Restart the local instance after changing.",
                    isOn: $developerLANExposureEnabled
                )
                .onChange(of: developerLANExposureEnabled) { oldValue, newValue in
                    if newValue && !oldValue {
                        showLANExposureWarning = true
                        developerLANExposureEnabled = false
                    } else if !newValue && oldValue {
                        manager.bindToLocalhostOnly = true
                        Task { await manager.restart() }
                    }
                }
                .onAppear {
                    developerLANExposureEnabled = !manager.bindToLocalhostOnly
                }
            }

            Text("Bundled SearXNG \(manager.bundledSearxngVersion) — updates ship with app updates.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            SettingsActionChipGrid {
                SettingsActionChip(title: "Open folder", systemImage: "folder") {
                    manager.openProjectFolderInFinder()
                }

                SettingsActionChip(title: "Rebuild fresh", systemImage: "arrow.clockwise") {
                    Task { await manager.recreateProjectFolder() }
                }
                .disabled(manager.isBusy)
            }

            SettingsLabeledField(
                title: "Custom local URL",
                description: "Only if you changed the default port (8080)."
            ) {
                HStack(spacing: 8) {
                    TextField("http://127.0.0.1:8080", text: $manualLocalURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addCustomLocalInstance() }
                        .disabled(manualLocalURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.top, 8)
    }

    private var needsFullSetup: Bool {
        !manager.projectFolderExists
    }

    private var isLocalInstanceActive: Bool {
        guard let active = activeInstance else { return false }
        return isLocalURL(active.url)
    }

    // MARK: - Instance list

    private var emptyInstancesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No instances yet")
                .font(.subheadline.weight(.medium))
            Text("Set up local search above, or add a remote instance below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func instanceCard(_ inst: SearXNGInstance) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isLocalURL(inst.url) ? "server.rack" : "globe")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(inst.name)
                        .font(.subheadline.weight(.semibold))
                    if isLocalURL(inst.url) {
                        SettingsBadge(text: "Local", tint: .green)
                    }
                }
                Text(inst.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if inst.id == currentInstanceID {
                SettingsBadge(text: "In use", tint: .accentColor)
            } else {
                Button("Use") { currentInstanceID = inst.id }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button(role: .destructive) {
                removeInstance(inst)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sheets

    private var setupLogsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Local setup log")
                .font(.headline)

            ScrollView {
                Text(manager.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.logs.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { showSetupLogs = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
    }

    // MARK: - Actions

    private func activateLocalInstance() {
        let localURL = manager.defaultLocalInstanceURL
        if let existing = searxInstances.first(where: { normalizeURL($0.url) == normalizeURL(localURL) }) {
            currentInstanceID = existing.id
            return
        }
        let inst = SearXNGInstance(name: "Local", url: localURL)
        searxInstances.append(inst)
        currentInstanceID = inst.id
    }

    private func addNewInstance() {
        let name = newInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.lowercased().hasPrefix("http") {
            url = "https://" + url
        }
        guard !name.isEmpty, !url.isEmpty else { return }

        let newInst = SearXNGInstance(name: name, url: url)
        searxInstances.append(newInst)
        currentInstanceID = newInst.id
        newInstanceName = ""
        newInstanceURL = ""
    }

    private func removeInstance(_ inst: SearXNGInstance) {
        searxInstances.removeAll { $0.id == inst.id }
        if currentInstanceID == inst.id, let first = searxInstances.first {
            currentInstanceID = first.id
        }
    }

    private func addCustomLocalInstance() {
        var url = manualLocalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.lowercased().hasPrefix("http") {
            url = "http://" + url
        }
        guard !url.isEmpty else { return }

        if let existing = searxInstances.first(where: { normalizeURL($0.url) == normalizeURL(url) }) {
            currentInstanceID = existing.id
        } else {
            let inst = SearXNGInstance(name: "Local", url: url)
            searxInstances.append(inst)
            currentInstanceID = inst.id
        }
        manualLocalURL = ""
    }

    private func isLocalURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("localhost") || lower.contains("127.0.0.1")
    }

    private func normalizeURL(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    // MARK: - Status helpers

    private func statusSystemImage(for status: SearxngStatus) -> String {
        switch status {
        case .running: return "checkmark.circle.fill"
        case .stopped: return "powerplug"
        case .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for status: SearxngStatus) -> Color {
        switch status {
        case .running: return .green
        case .stopped: return .secondary
        case .starting, .stopping: return .orange
        case .error: return .red
        }
    }

    private func statusBadge(for status: SearxngStatus) -> String {
        switch status {
        case .running: return "Ready"
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }

    private func statusTitle(for status: SearxngStatus) -> String {
        switch status {
        case .running: return "Local SearXNG is running"
        case .stopped: return "Local SearXNG is stopped"
        case .starting: return "Starting local SearXNG…"
        case .stopping: return "Stopping local SearXNG…"
        case .error: return "Local setup needs attention"
        }
    }

    private func statusDescription(for status: SearxngStatus) -> String {
        switch status {
        case .running:
            return "Searches run through your private SearXNG on this Mac."
        case .stopped:
            return "Tap Start to launch SearXNG, or use Set up local search."
        case .starting, .stopping:
            return "Please wait a moment."
        case .error:
            return "Check the message below or open the setup log."
        }
    }
}