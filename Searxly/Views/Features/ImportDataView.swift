//
//  ImportDataView.swift
//  Searxly
//
//  Unified "Import data from other browsers" hub. The user picks what to bring over (bookmarks or
//  passwords); each source opens its own file picker and reports a result inline. This is the single
//  discoverable entry point surfaced from the Bookmarks page, Settings, and onboarding.
//

import SwiftUI

struct ImportDataView: View {
    @Bindable var browserState: BrowserState
    let glassEnabled: Bool
    var onClose: () -> Void

    @State private var bookmarkStatus: String?
    @State private var passwordStatus: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 14) {
                    importCard(
                        icon: "bookmark.fill",
                        title: "Bookmarks",
                        subtitle: "From an HTML file exported by Safari, Chrome, Firefox, Edge, Brave, or Arc (File → Export Bookmarks…).",
                        actionTitle: "Choose HTML File…",
                        status: bookmarkStatus,
                        footnote: nil,
                        action: importBookmarks
                    )

                    // Password CSV import lands in the vault, which is Maximum-exclusive.
                    if PasswordVaultManager.isAvailable {
                        importCard(
                            icon: "key.fill",
                            title: "Passwords",
                            subtitle: "From a CSV exported by your browser or password manager (Chrome, Safari, Firefox, Bitwarden, 1Password…). Saved encrypted in your vault.",
                            actionTitle: "Choose CSV File…",
                            status: passwordStatus,
                            footnote: "The CSV contains plain-text passwords. Delete it securely once the import finishes.",
                            action: importPasswords
                        )
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 540, height: 500)
        .background(
            glassEnabled ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial)
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Data")
                    .font(.system(size: 17, weight: .semibold))
                Text(PasswordVaultManager.isAvailable
                     ? "Bring your bookmarks and passwords over from another browser."
                     : "Bring your bookmarks over from another browser.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if working { ProgressView().scaleEffect(0.7) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func importCard(
        icon: String,
        title: String,
        subtitle: String,
        actionTitle: String,
        status: String?,
        footnote: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(working)
                if let status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 38)

            if let footnote {
                Label(footnote, systemImage: "exclamationmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Actions

    private func importBookmarks() {
        guard let url = BookmarkImporter.pickBookmarksFile() else { return }
        working = true
        Task {
            let result = await BookmarkImporter.importBookmarks(from: url, mergingInto: browserState.bookmarks)
            browserState.bookmarks = result.bookmarks
            Persistence.saveBookmarks(browserState.bookmarks)
            bookmarkStatus = bookmarkMessage(result.summary)
            working = false
        }
    }

    private func importPasswords() {
        guard let url = PasswordCSVImporter.pickCSVFile() else { return }
        working = true
        Task {
            let outcome = await PasswordCSVImporter.importPasswords(from: url)
            passwordStatus = passwordMessage(outcome)
            working = false
        }
    }

    // MARK: - Result messages

    private func bookmarkMessage(_ s: BookmarkImporter.Summary) -> String {
        if s.total == 0 { return "No bookmarks found in that file. Make sure it's an exported HTML bookmarks file." }
        if s.imported == 0 { return "All \(s.total) bookmarks were already saved." }
        let base = "Imported \(s.imported) bookmark\(s.imported == 1 ? "" : "s")."
        return s.skipped > 0 ? "\(base) \(s.skipped) already saved." : base
    }

    private func passwordMessage(_ outcome: PasswordCSVImporter.Outcome) -> String {
        switch outcome {
        case .unreadable:
            return "Couldn't read that file."
        case .noRows:
            return "That file has no logins."
        case .unrecognizedColumns:
            return "Couldn't find URL/password columns. Export a passwords CSV (with a header row) and try again."
        case .imported(let s):
            if s.imported == 0 && s.skipped == 0 && s.failed == 0 { return "No logins found in that file." }
            var parts = ["Imported \(s.imported) login\(s.imported == 1 ? "" : "s")."]
            if s.withTOTP > 0 { parts.append("\(s.withTOTP) brought two-factor keys across.") }
            if s.skipped > 0 { parts.append("\(s.skipped) already in your vault.") }
            if s.failed > 0 { parts.append("\(s.failed) skipped (missing fields).") }
            return parts.joined(separator: " ")
        }
    }
}
