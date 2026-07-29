//
//  SettingsView.swift
//  Searxly
//
//  Sidebar-navigated Settings with clear categories.
//  Custom old design: SidebarCategoryRow + HStack split + manual detail ScrollView.
//  Per-pane content uses .padding(.horizontal, 24).padding(.vertical, 20) VStacks (no Form/centering).
//

import SwiftUI
import UniformTypeIdentifiers   // for .data in NSSavePanel (backup)

/// Sidebar groupings for clearer navigation.
enum SettingsSidebarGroup: String, CaseIterable, Identifiable {
    case general = "General"
    case privacy = "Privacy & Security"
    case search = "Search"
    case features = "Features"
    case support = "Support"

    var id: String { rawValue }

    var categories: [SettingsCategory] {
        switch self {
        case .general:
            return [.appearance]
        case .privacy:
            // VPN is offered in both editions now: base app = a paid managed pass; Maximum = the faster
            // protection network (included free for 45 days, then falls back to Tor). Privacy Report leads
            // the group: a glanceable posture score before the controls.
            // Password vault is Maximum-exclusive (same product rule as PasswordVaultManager.isAvailable).
            if PasswordVaultManager.isAvailable {
                return [.privacyReport, .privacy, .security, .passwords, .vpn, .tor]
            }
            return [.privacyReport, .privacy, .security, .vpn, .tor]
        case .search:
            return [.search, .instances]
        case .features:
            // Searxly Maximum drops the crypto wallet; AI is on-device only (no Searxly AI cloud).
            var categories: [SettingsCategory] = Edition.isMaximum ? [.agenticTools, .performance] : [.agenticTools, .wallet, .performance]
            if ExtensionFeatures.programEnabled {
                categories.insert(.extensions, at: categories.count - 1)
            }
            return categories
        case .support:
            // Support leads the group: the hand-off to the hosted support center (tickets) sits above
            // the in-app Feedback form. Searxly Maximum has no feedback webhook (nothing posts outward),
            // but still surfaces the support center.
            return Edition.isMaximum ? [.support, .about, .legal] : [.support, .feedback, .about, .legal]
        }
    }
}

/// Categories for the Settings sidebar navigation.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case privacyReport = "Privacy Report"
    case privacy = "Privacy & Data"
    case security = "App Security"
    case passwords = "Passwords"
    case vpn = "VPN"
    case tor = "Tor"
    case performance = "Performance"
    case extensions = "Extensions"
    case search = "Search"
    case instances = "SearXNG Instances"
    case wallet = "Wallet"
    case agenticTools = "Agentic Tools"
    case support = "Support"
    case feedback = "Feedback"
    case about = "About"
    case legal = "Legal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .privacyReport: return "checkmark.seal.fill"
        case .privacy: return "lock.shield.fill"
        case .security: return "lock.fill"
        case .passwords: return "key.fill"
        case .vpn: return "network.badge.shield.half.filled"
        case .tor: return "point.3.connected.trianglepath.dotted"
        case .wallet:      return "hexagon.fill"
        case .agenticTools: return "wrench.and.screwdriver.fill"
        case .performance: return "speedometer"
        case .extensions: return "puzzlepiece.extension.fill"
        case .search: return "text.magnifyingglass"
        case .instances: return "network"
        case .support: return "lifepreserver.fill"
        case .feedback: return "exclamationmark.bubble.fill"
        case .about: return "info.circle"
        case .legal: return "doc.text"
        }
    }

    var localizedTitle: String {
        switch self {
        case .appearance:  return Localization.string("appearance_title", defaultValue: "Appearance")
        case .privacyReport: return Localization.string("privacy_report_title", defaultValue: "Privacy Report")
        case .privacy:     return Localization.string("privacy_title", defaultValue: "Privacy & Data")
        case .security:    return Localization.string("security_title", defaultValue: "App Security")
        case .passwords:   return Localization.string("passwords_title", defaultValue: "Passwords")
        case .vpn:         return Localization.string("vpn_title", defaultValue: "VPN")
        case .tor:         return Localization.string("tor_title", defaultValue: "Tor / Onion")
        case .performance: return Localization.string("performance_title", defaultValue: "Performance")
        case .extensions:  return Localization.string("extensions_title", defaultValue: "Extensions")
        case .search:      return Localization.string("search_settings_title", defaultValue: "Search")
        case .instances:   return Localization.string("instances_title", defaultValue: "SearXNG Instances")
        case .wallet:      return "Wallet"
        case .agenticTools: return Localization.string("agentic_tools_title", defaultValue: "Agentic Tools")
        case .support:     return Localization.string("support_title", defaultValue: "Support")
        case .feedback:    return Localization.string("feedback_title", defaultValue: "Feedback")
        case .about:       return Localization.string("about_title", defaultValue: "About")
        case .legal:       return Localization.string("legal_title", defaultValue: "Legal")
        }
    }
}

struct SettingsView: View {
    @Binding var reduceLiquidGlass: Bool
    @Binding var searxInstances: [SearXNGInstance]
    @Binding var currentInstanceID: UUID
    @Binding var knowledgePanelEnabled: Bool

    /// Binding to let Settings trigger the advanced Clear Browsing Data sheet (owned by ContentView).
    @Binding var showingClearData: Bool

    /// The sidebar category to show when the sheet opens. Defaults to Appearance.
    var initialCategory: SettingsCategory = .appearance

    @Environment(\.dismiss) private var dismiss

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearanceMode") private var appearanceModeRaw: String = "system"
    // Local UI state for the toggle. Synced with PrivacyManager (which now owns the value persisted inside AppData.json).
    @State private var historyEnabled: Bool = PrivacyManager.shared.historyEnabled

    // New tab privacy default preference (on by default = Maximum privacy leaning).
    @State private var defaultNewTabsToPrivate: Bool = PrivacyManager.shared.defaultNewTabsToPrivate

    // Optional at-rest encryption for the main local data file.
    @State private var dataEncryptionEnabled: Bool = PrivacyManager.shared.dataEncryptionEnabled


    // For feedback after clearing data
    @State private var showClearConfirmation = false
    @State private var clearedMessage = ""

    // Backup / Restore state (shared with the BackupPasswordSheet and Privacy/Security panes)
    @State private var showingBackupPasswordPrompt = false
    @State private var backupPassword = ""
    @State private var pendingRestoreURL: URL? = nil   // for restore flow

    // Re-auth state for biometric confirmation on sensitive actions (no more PIN sheets)
    @State private var pendingReauthAction: (() -> Void)? = nil

    // Currently selected category in the left sidebar (seeded from initialCategory on appear)
    @State private var selectedCategory: SettingsCategory = .appearance

    // Settings search (Searxly Maximum): the query drives the floating results panel below the header.
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            // Base app keeps the hard hairline; Searxly Maximum relies on the raised-header/darker-
            // content tonal step alone, so there's no flat line cutting across behind the search.
            if !Edition.isMaximum {
                Rectangle().fill(SettingsTheme.hairline).frame(height: 1)
            }

            HStack(spacing: 0) {
                sidebarView
                contentColumn
            }
        }
        // Results popup, anchored directly under the search field (not centered in the content area).
        // It springs OUT of the bar: the scale transition is anchored to the panel's top edge — which
        // sits just under the field — so the dark-glass panel grows downward from the search bar.
        .overlayPreferenceValue(SearchFieldBoundsKey.self) { anchor in
            if Edition.isMaximum, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        SettingsSearchResults(query: searchQuery) { entry in
                            selectedCategory = entry.category
                            searchQuery = ""
                            searchFocused = false
                        }
                        // Transition first (so scale anchors to the panel's own top), then position:
                        // centre the 420-wide panel on the field's midX, dropped just below it.
                        .transition(.scale(scale: 0.86, anchor: .top).combined(with: .opacity))
                        .offset(x: rect.midX - 210, y: rect.maxY + 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: searchQuery.isEmpty)
            }
        }
        // minHeight kept low so the sheet can shrink to fit short parent windows / laptop screens
        // instead of overflowing and clipping the header (top) and the last sidebar item (bottom).
        // Both columns scroll internally, so a smaller height stays fully usable.
        .frame(minWidth: 800, idealWidth: 860, maxWidth: 920, minHeight: 420, idealHeight: 660)
        .background(SettingsTheme.canvas)
        .onAppear { selectedCategory = initialCategory }
        .alert("Notice", isPresented: $showClearConfirmation) {
            Button("OK") { }
        } message: {
            Text(clearedMessage)
        }
        .sheet(isPresented: $showingBackupPasswordPrompt) {
            BackupPasswordSheet(
                isRestore: pendingRestoreURL != nil,
                password: $backupPassword,
                onCancel: {
                    showingBackupPasswordPrompt = false
                    pendingRestoreURL = nil
                    backupPassword = ""
                },
                onConfirm: {
                    if pendingRestoreURL == nil {
                        performCreateBackup()
                    } else {
                        performRestoreBackup()
                    }
                }
            )
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text(Localization.string("settings_title", defaultValue: "Settings"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SettingsTheme.textPrimary)
            // Edition insignia — quiet small-caps wordmark in a hairline capsule, monochrome like
            // everything else. The one place Settings states which product this is.
            if Edition.isMaximum {
                Text("MAXIMUM")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(SettingsTheme.hairlineStrong, lineWidth: 1))
            }
            Spacer()
            if Edition.isMaximum {
                SettingsSearchField(query: $searchQuery, onSubmit: {
                    // Return opens the top-ranked result.
                    if let first = SettingsSearchIndex.search(searchQuery).first {
                        selectedCategory = first.category
                        searchQuery = ""
                        searchFocused = false
                    }
                }, focused: $searchFocused)
                // ⌘F focuses the search field (the hint the field shows). Zero-size, invisible.
                .background(
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                )
                Spacer()
            }
            Button {
                dismiss()
            } label: {
                Text(Localization.string("settings_done", defaultValue: "Done"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.onInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(SettingsTheme.inkFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        // Clear the macOS floating-sheet titlebar drag strip that otherwise clips the top row.
        .padding(.top, 42)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(SettingsTheme.canvasRaised)
    }

    // MARK: - Content column (one centered reading column shared by every pane)

    private var contentColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            paneContent
                .frame(maxWidth: 540, alignment: .leading)   // the reading column
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 44)
                .tint(SettingsTheme.textPrimary)
                .toggleStyle(PremiumToggleStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.canvas)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedCategory {
        case .appearance:
            AppearanceSettingsView(reduceLiquidGlass: $reduceLiquidGlass, appearanceModeRaw: $appearanceModeRaw)
        case .privacyReport:
            PrivacyReportView(onNavigate: { selectedCategory = $0 })
        case .privacy:
            PrivacySettingsView(
                historyEnabled: $historyEnabled,
                defaultNewTabsToPrivate: $defaultNewTabsToPrivate,
                dataEncryptionEnabled: $dataEncryptionEnabled,
                clearedMessage: $clearedMessage,
                showClearConfirmation: $showClearConfirmation,
                showingClearData: $showingClearData,
                requestReauth: requestReauthForSensitiveAction,
                onExportRecovery: {
                    if PrivacyManager.shared.copyEncryptionRecoveryCodeToClipboard() {
                        clearedMessage = Localization.string("recovery_code_copied", defaultValue: "Recovery code copied — paste it somewhere safe now. The clipboard clears itself after 45 seconds.")
                        showClearConfirmation = true
                    } else {
                        clearedMessage = Localization.string("no_encryption_key", defaultValue: "No encryption key found to export.")
                        showClearConfirmation = true
                    }
                },
                onNavigate: { selectedCategory = $0 }
            )
        case .security:
            SecuritySettingsView(
                onCreateBackup: { createBackup() },
                onRestoreBackup: { restoreBackup() }
            )
        case .passwords:
            PasswordsSettingsView(onOpenVault: openPasswordVaultFromSettings)
        case .vpn:
            // Both editions buy/renew a Searxly VPN pass here; Maximum's pane drops the crypto rail (no
            // wallet in that edition) and leads with the included welcome comp. Which network Maximum
            // Privacy actually rides — Tor or this VPN — is a Privacy & Data setting, not a VPN one.
            if Edition.isMaximum {
                VPNMaximumView(onNavigate: { selectedCategory = $0 })
            } else {
                VPNManagedView()
            }
        case .tor:
            TorSettingsView()
        case .performance:
            PerformanceSettingsView()
        case .extensions:
            ExtensionsSettingsView()
        case .search:
            SearchSettingsView(knowledgePanelEnabled: $knowledgePanelEnabled)
        case .instances:
            InstancesSettingsView(
                searxInstances: $searxInstances,
                currentInstanceID: $currentInstanceID
            )
        case .agenticTools:
            AgenticToolsSettingsView()
        case .wallet:
            WalletSettingsSection()
        case .support:
            SupportSettingsView()
        case .feedback:
            FeedbackSettingsView(
                searxInstances: $searxInstances,
                currentInstanceID: $currentInstanceID
            )
        case .about:
            AboutSettingsView()
        case .legal:
            LegalSettingsView()
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        // Scrollable so the last items (Feedback / About) are always reachable even when the Settings
        // sheet is shorter than the full category list (short parent window / laptop screen). Shows the
        // standard macOS scroller so it's obvious the list scrolls.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSidebarGroup.allCases) { group in
                    Text(group.rawValue.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(SettingsTheme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, group == SettingsSidebarGroup.allCases.first ? 2 : 16)
                        .padding(.bottom, 5)

                    ForEach(group.categories) { category in
                        SidebarCategoryRow(
                            category: category,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
            }
            .frame(width: 208, alignment: .leading)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .padding(.horizontal, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.canvasRaised)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(SettingsTheme.hairline)
                .frame(width: 1)
        }
    }

    private func openPasswordVaultFromSettings() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .showPasswordsVaultTabRequested, object: nil)
        }
    }

    // MARK: - Biometric re-auth for sensitive actions (replaces all old PIN re-auth UI)

    private func requestBiometricReauth(_ action: @escaping () -> Void, onFailure: (() -> Void)? = nil) {
        pendingReauthAction = action

        Task { @MainActor in
            let success = await AppLockManager.shared.authenticateWithBiometrics(
                reason: "Confirm to change security settings"
            )

            if success {
                let actionToRun = pendingReauthAction
                pendingReauthAction = nil
                // Slight delay for sheet / UI niceness
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    actionToRun?()
                }
            } else {
                // User cancelled or failed — just clear pending; no action runs.
                pendingReauthAction = nil
                onFailure?()
            }
        }
    }

    // Legacy name used by a few call sites in the privacy section — keep a thin forwarding impl.
    private func requestReauthForSensitiveAction(_ action: @escaping () -> Void, onFailure: (() -> Void)? = nil) {
        requestBiometricReauth(action, onFailure: onFailure)
    }

    private func createBackup() {
        backupPassword = ""
        showingBackupPasswordPrompt = true
    }

    private func performCreateBackup() {
        guard !backupPassword.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Create Encrypted Searxly Backup"
        panel.nameFieldStringValue = "SearxlyBackup-\(Date().formatted(.iso8601.year().month().day())).searxlybackup"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try BackupManager.createBackup(to: url, password: backupPassword, includeKey: true)
                showClearConfirmation = true
                clearedMessage = "Backup created successfully at \(url.lastPathComponent)"
            } catch {
                showClearConfirmation = true
                clearedMessage = "Backup failed: \(error.localizedDescription)"
            }
        }
        showingBackupPasswordPrompt = false
        backupPassword = ""
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = "Restore from Encrypted Backup"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            pendingRestoreURL = url
            backupPassword = ""
            showingBackupPasswordPrompt = true
        }
    }

    private func performRestoreBackup() {
        guard let url = pendingRestoreURL, !backupPassword.isEmpty else {
            pendingRestoreURL = nil
            showingBackupPasswordPrompt = false
            return
        }

        do {
            let keyWasRestored = try BackupManager.restore(from: url, password: backupPassword)
            let msg = keyWasRestored
                ? "Backup restored successfully (including encryption key)."
                : "Backup restored. Encryption key was not included in the backup."
            clearedMessage = msg
            showClearConfirmation = true

            // Notify the rest of the app to reload data (history, bookmarks, instances, privacy settings, etc.)
            NotificationCenter.default.post(name: .dataRestoredFromBackup, object: nil)
        } catch {
            clearedMessage = "Restore failed: \(error.localizedDescription)"
            showClearConfirmation = true
        }

        pendingRestoreURL = nil
        backupPassword = ""
        showingBackupPasswordPrompt = false
    }
}

// MARK: - Sidebar row component (premium flat style matching app sidebar, restored for visual appeal)

private struct SidebarCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)

                Text(category.localizedTitle)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SettingsTheme.textPrimary : SettingsTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? SettingsTheme.fillStrong
                          : (isHovering ? SettingsTheme.fillSubtle : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? SettingsTheme.hairline : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Defer to prevent "Modifying state during view update" warning.
            DispatchQueue.main.async {
                isHovering = hovering
            }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}


