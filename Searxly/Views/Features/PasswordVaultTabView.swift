//
//  PasswordVaultTabView.swift
//  Searxly
//

import SwiftUI
import AppKit

struct PasswordVaultTabView: View {
    let tab: BrowserTab
    let glassEnabled: Bool
    let toolbarMaterial: Material

    var onFillLogin: (String, String, String) -> Void = { _, _, _ in }
    var onOpenSite: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var editingEntry: PasswordVaultEntry?
    @State private var entryToDelete: PasswordVaultEntry?
    @State private var statusMessage: String?
    @State private var health: [UUID: PasswordHealth.Report] = [:]   // offline password-health reports

    // Inline password reveal: which entry is showing its plaintext, the value, and an auto-hide task.
    @State private var revealedEntryID: UUID?
    @State private var revealedPassword: String = ""
    @State private var revealHideTask: Task<Void, Never>?

    private var vault = PasswordVaultManager.shared

    /// Recomputes password health locally (reuse / weak / known-common). Only meaningful while the
    /// vault is unlocked, which is the only time this content is on screen.
    private func refreshHealth() { health = vault.healthReports() }

    private var filteredEntries: [PasswordVaultEntry] {
        vault.entries(matching: searchText)
    }

    private var groupedEntries: [(domain: String, entries: [PasswordVaultEntry])] {
        let grouped = Dictionary(grouping: filteredEntries, by: \.domain)
        return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (domain: $0, entries: grouped[$0]!.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }) }
    }

    private var uniqueSiteCount: Int {
        Set(vault.entries.map(\.domain)).count
    }

    private var recentEntries: [PasswordVaultEntry] {
        vault.entries
            .filter { $0.lastUsed != nil }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if vault.isVaultUnlocked {
                unlockedContent
            } else {
                PasswordVaultLockView(glassEnabled: glassEnabled, toolbarMaterial: toolbarMaterial) {
                    vault.reloadFromPersistence()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(vaultBackground)
        .onAppear {
            vault.reloadFromPersistence()
        }
        .sheet(isPresented: $showingAddSheet) {
            PasswordEntryEditorSheet(
                mode: .add,
                onCancel: { showingAddSheet = false },
                onSaved: {
                    showingAddSheet = false
                    flashStatus("Login saved")
                }
            )
        }
        .sheet(item: $editingEntry) { entry in
            PasswordEntryEditorSheet(
                mode: .edit(entry),
                onCancel: { editingEntry = nil },
                onSaved: {
                    editingEntry = nil
                    flashStatus("Login updated")
                }
            )
        }
        .alert("Delete login?", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    vault.deleteEntry(id: entry.id)
                    flashStatus("Login removed")
                }
                entryToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            if let entry = entryToDelete {
                Text("Remove \(entry.username) for \(entry.domain)? This cannot be undone.")
            }
        }
    }

    private var vaultBackground: some View {
        ZStack {
            AdaptiveChrome.appCanvas(colorScheme, glassEnabled: glassEnabled)
                .ignoresSafeArea()

            if glassEnabled, colorScheme == .dark {
                RadialGradient(
                    colors: [Color.white.opacity(0.04), Color.clear],
                    center: .top,
                    startRadius: 24,
                    endRadius: 420
                )
                .ignoresSafeArea()
            }
        }
    }

    private var unlockedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroHeader

                if let statusMessage {
                    statusBanner(statusMessage)
                }

                let riskCount = health.values.filter { $0.atRisk }.count
                if riskCount > 0 { attentionBanner(riskCount) }

                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    if !isSearching, !recentEntries.isEmpty {
                        recentSection
                    }
                    allLoginsSection
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refreshHealth() }
        .onChange(of: vault.entries) { _, _ in refreshHealth() }
        // Locking the vault must not leave a revealed password sitting in @State memory / on screen.
        .onChange(of: vault.isVaultUnlocked) { _, unlocked in if !unlocked { hideRevealedPassword() } }
    }

    /// Banner summarising how many saved passwords are reused, weak, or known-breached.
    private func attentionBanner(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("\(count) password\(count == 1 ? "" : "s") need attention")
                .font(.caption.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    /// Small per-entry risk chip (highest-severity issue first). Empty for healthy passwords.
    @ViewBuilder
    private func healthBadge(_ entry: PasswordVaultEntry) -> some View {
        if let report = health[entry.id], report.atRisk {
            let (label, icon): (String, String) =
                report.common ? ("Known password", "exclamationmark.shield")
                : report.reused ? ("Reused", "arrow.triangle.2.circlepath")
                : ("Weak", "exclamationmark.triangle")
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.14), lineWidth: 1)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "key.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.primary.opacity(0.68))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password Vault")
                        .font(.title.weight(.semibold))
                    Text("Saved logins stay on this Mac, encrypted in Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        vault.lockVault()
                    } label: {
                        Label("Lock", systemImage: "lock.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Login", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if vault.savedLoginCount > 0 {
                HStack(spacing: 10) {
                    statPill(value: "\(vault.savedLoginCount)", label: vault.savedLoginCount == 1 ? "Login" : "Logins", icon: "person.badge.key.fill")
                    statPill(value: "\(uniqueSiteCount)", label: uniqueSiteCount == 1 ? "Site" : "Sites", icon: "globe")
                    statPill(value: autoLockLabel, label: "Auto-lock", icon: "clock.fill")
                }
            }

            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by site, username, or notes…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            if glassEnabled {
                shape.fill(toolbarMaterial)
            } else {
                shape.fill(AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.12), lineWidth: 1)
        )
    }

    private func statPill(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.6)
        )
    }

    private var autoLockLabel: String {
        let minutes = vault.autoLockMinutes
        if minutes == 0 { return "Off" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours == 1 ? "1h" : "\(hours)h"
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: isSearching ? "magnifyingglass" : "tray")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(isSearching ? "No matches" : "Your vault is empty")
                    .font(.title3.weight(.semibold))
                Text(isSearching
                     ? "Try a different search term or clear the filter."
                     : "Save logins as you browse, or add one manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            if !isSearching {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GET STARTED")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)

                    VStack(spacing: 0) {
                        tipRow(
                            icon: "key.fill",
                            title: "Save from a sign-in page",
                            detail: "Use the key icon in the browser toolbar when you're on a login form."
                        )
                        Divider().padding(.leading, 44)
                        tipRow(
                            icon: "plus.circle.fill",
                            title: "Add manually",
                            detail: "Store a username and password for any site right here."
                        )
                        Divider().padding(.leading, 44)
                        tipRow(
                            icon: "wand.and.stars",
                            title: "Generate strong passwords",
                            detail: "On signup pages, generate and fill a secure password in one tap."
                        )
                    }
                    .padding(14)
                    .background { cardSurfaceShape(cornerRadius: 12) }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 1)
                    )
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Your First Login", systemImage: "plus")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tipRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recently used", icon: "clock.arrow.circlepath")

            VStack(spacing: 6) {
                ForEach(recentEntries) { entry in
                    compactEntryRow(entry)
                }
            }
        }
    }

    private var allLoginsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                isSearching ? "Search results" : "All logins",
                icon: isSearching ? "magnifyingglass" : "list.bullet.rectangle"
            )

            ForEach(groupedEntries, id: \.domain) { group in
                domainSection(group)
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.4)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func domainSection(_ group: (domain: String, entries: [PasswordVaultEntry])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                siteIcon(for: group.domain)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.domain)
                        .font(.headline)
                    Text("\(group.entries.count) \(group.entries.count == 1 ? "login" : "logins")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onOpenSite(group.domain)
                } label: {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            VStack(spacing: 6) {
                ForEach(group.entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .padding(14)
        .background { cardSurfaceShape(cornerRadius: 14) }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 1)
        )
    }

    private func cardSurfaceShape(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if glassEnabled {
                shape.fill(toolbarMaterial)
                    .searxlyGlass(.regular, in: shape)
            } else {
                shape.fill(AdaptiveChrome.fill(colorScheme, dark: 0.03, light: 0.025))
            }
        }
    }

    private func compactEntryRow(_ entry: PasswordVaultEntry) -> some View {
        HStack(spacing: 12) {
            siteIcon(for: entry.domain)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.username)
                        .font(.subheadline.weight(.medium))
                    healthBadge(entry)
                }
                Text(entry.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Fill") { fillEntry(entry) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(12)
        .background(
            AdaptiveChrome.fill(colorScheme, dark: 0.04, light: 0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.08), lineWidth: 0.6)
        )
    }

    private func entryRow(_ entry: PasswordVaultEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.username)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)
                        healthBadge(entry)
                    }
                    if let notes = entry.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let lastUsed = entry.lastUsed {
                        Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    actionButton("Fill this login", systemImage: "arrow.down.to.line") {
                        fillEntry(entry)
                    }

                    actionButton("Copy username", systemImage: "person") {
                        copyUsername(entry)
                    }

                    actionButton("Copy password", systemImage: "key") {
                        if vault.copyPasswordToClipboard(for: entry.id) {
                            flashStatus("Password copied — clears in 45s")
                        }
                    }

                    actionButton(revealedEntryID == entry.id ? "Hide password" : "Reveal password",
                                 systemImage: revealedEntryID == entry.id ? "eye.slash" : "eye") {
                        toggleReveal(entry)
                    }

                    actionButton("Edit", systemImage: "pencil") {
                        editingEntry = entry
                    }

                    actionButton("Delete", systemImage: "trash", tint: .secondary) {
                        entryToDelete = entry
                    }
                }
            }

            if revealedEntryID == entry.id {
                HStack(spacing: 8) {
                    Text(revealedPassword.isEmpty ? "—" : revealedPassword)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("Hides automatically")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AdaptiveChrome.fill(colorScheme, dark: 0.05, light: 0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(AdaptiveChrome.fill(colorScheme, dark: 0.03, light: 0.02), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionButton(_ help: String, systemImage: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(AdaptiveChrome.fill(colorScheme, dark: 0.05, light: 0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func siteIcon(for domain: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AdaptiveChrome.fill(colorScheme, dark: 0.06, light: 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 1)
                )
            Text(String(domain.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    private func fillEntry(_ entry: PasswordVaultEntry) {
        guard vault.autofillEnabled else {
            flashStatus("Autofill is disabled in Settings")
            return
        }
        guard let password = vault.password(for: entry.id) else {
            flashStatus("Could not read password")
            return
        }
        vault.markEntryUsed(id: entry.id)
        onFillLogin(entry.domain, entry.username, password)
        flashStatus("Filled \(entry.username)")
    }

    /// Copies the username. Not a secret, so it uses the normal pasteboard (no auto-clear), unlike
    /// the password copy which routes through VaultClipboardManager.
    private func copyUsername(_ entry: PasswordVaultEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.username, forType: .string)
        flashStatus("Username copied")
    }

    /// Toggles inline plaintext reveal for one entry. Reading the secret goes through the unlock-gated
    /// `password(for:)`; the reveal auto-hides after 20s and whenever another entry is revealed.
    private func toggleReveal(_ entry: PasswordVaultEntry) {
        if revealedEntryID == entry.id { hideRevealedPassword(); return }
        guard let password = vault.password(for: entry.id) else {
            flashStatus("Could not read password")
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            revealedEntryID = entry.id
            revealedPassword = password
        }
        revealHideTask?.cancel()
        revealHideTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run { hideRevealedPassword() }
        }
    }

    private func hideRevealedPassword() {
        revealHideTask?.cancel()
        revealHideTask = nil
        withAnimation(.easeOut(duration: 0.15)) {
            revealedEntryID = nil
            revealedPassword = ""
        }
    }

    private func flashStatus(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            statusMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                withAnimation {
                    if statusMessage == message {
                        statusMessage = nil
                    }
                }
            }
        }
    }
}