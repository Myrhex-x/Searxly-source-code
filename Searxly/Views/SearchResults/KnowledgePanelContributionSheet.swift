//
//  KnowledgePanelContributionSheet.swift
//  Searxly
//
//  In-context contributions for the SERP knowledge panel (errors, change requests, etc.).
//

import SwiftUI

struct KnowledgePanelContributionSheet: View {
    let content: KnowledgePanelContent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedType: ContributionType = .error
    @State private var message: String = ""
    @State private var includePanelContext: Bool = true
    @State private var includeAppInfo: Bool = true

    @State private var isSending = false
    @State private var sendSuccessMessage: String? = nil
    @State private var sendError: String? = nil
    @State private var copyMessage: String? = nil

    private enum ContributionType: String, CaseIterable {
        case error, change, missing, other

        var displayName: String {
            switch self {
            case .error: return "Report error"
            case .change: return "Request change"
            case .missing: return "Missing info"
            case .other: return "Other"
            }
        }

        var shortLabel: String {
            switch self {
            case .error: return "ERROR"
            case .change: return "CHANGE"
            case .missing: return "MISSING"
            case .other: return "OTHER"
            }
        }

        var prompt: String {
            switch self {
            case .error:
                return "What looks wrong? Include what you expected instead."
            case .change:
                return "What should we update in this panel?"
            case .missing:
                return "What information is missing or incomplete?"
            case .other:
                return "Share any other feedback about this knowledge panel."
            }
        }

        var embedColor: Int {
            switch self {
            case .error: return 0xEF4444
            case .change: return 0x3B82F6
            case .missing: return 0xF59E0B
            case .other: return 0x8B5CF6
            }
        }
    }

    private var panelSubject: String {
        if case .entity(let data) = content.kind {
            return data.title
        }
        return content.query
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contextCard

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Contribution type")
                            .font(.subheadline.weight(.semibold))

                        Picker("Contribution type", selection: $selectedType) {
                            ForEach(ContributionType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your message")
                            .font(.subheadline.weight(.semibold))

                        TextEditor(text: $message)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 130, maxHeight: 200)
                            .padding(10)
                            .background(AdaptiveChrome.fill(colorScheme, dark: 0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 0.5)
                            )

                        Text(selectedType.prompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Include with report")
                            .font(.subheadline.weight(.semibold))

                        toggleRow(
                            title: "Panel context",
                            description: "Search query, subject, Grokipedia link, and a short content preview",
                            isOn: $includePanelContext
                        )

                        Divider().opacity(0.2)

                        toggleRow(
                            title: "App and macOS version",
                            description: appVersionLine,
                            isOn: $includeAppInfo
                        )
                    }
                    .padding(14)
                    .background(panelChromeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.09), lineWidth: 0.5)
                    )

                    if let success = sendSuccessMessage {
                        statusBanner(
                            title: "Thank you!",
                            message: success,
                            tint: .primary.opacity(0.85),
                            systemImage: "checkmark.circle.fill"
                        )
                    }

                    if let error = sendError {
                        statusBanner(
                            title: "Could not send",
                            message: error,
                            tint: .orange,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }

                    if let copyMsg = copyMessage {
                        Text(copyMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            sheetFooter
        }
        .frame(width: 440, height: 560)
        .background(sheetCanvas)
        .onChange(of: message) { _, _ in
            if sendSuccessMessage != nil || sendError != nil {
                sendSuccessMessage = nil
                sendError = nil
            }
        }
    }

    // MARK: - Chrome

    private var sheetCanvas: some View {
        ZStack {
            if colorScheme == .dark {
                AdaptiveChrome.canvasDark
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AdaptiveChrome.fill(colorScheme, dark: 0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: "text.book.closed")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Contribute to this panel")
                    .font(.title3.weight(.semibold))
                Text("Help improve Grokipedia knowledge for \"\(panelSubject)\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(AdaptiveChrome.fill(colorScheme, dark: 0.04))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)
        }
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(panelKindLabel, systemImage: panelKindIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            Text(panelSubject)
                .font(.headline)
                .foregroundStyle(.primary)

            if let preview = panelPreviewLine {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(panelChromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdaptiveChrome.border(colorScheme, dark: 0.1), lineWidth: 0.5)
        )
    }

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            Button("Copy report") {
                copyReportToClipboard()
            }
            .buttonStyle(.link)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await sendContribution() }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().controlSize(.small)
                        Text("Sending…")
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("Send contribution")
                    }
                }
                .frame(minWidth: 148)
            }
            .buttonStyle(.bordered)
            .disabled(!canSend)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(AdaptiveChrome.fill(colorScheme, dark: 0.04))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AdaptiveChrome.divider(colorScheme))
                .frame(height: 1)
        }
    }

    private var panelChromeBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AdaptiveChrome.fill(colorScheme, dark: colorScheme == .dark ? 0.05 : 0.035))
    }

    private var panelKindLabel: String { "Grokipedia panel" }

    private var panelKindIcon: String { "book.closed" }

    private var panelPreviewLine: String? {
        if case .entity(let data) = content.kind {
            return data.aboutParagraphs.first
        }
        return nil
    }

    private var appVersionLine: String {
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(shortVer) (build \(build)) on \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    @ViewBuilder
    private func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder
    private func statusBanner(
        title: String,
        message: String,
        tint: Color,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Delivery

    private func sendContribution() async {
        guard canSend else { return }

        isSending = true
        sendSuccessMessage = nil
        sendError = nil
        copyMessage = nil

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "[\(selectedType.shortLabel)] \(panelSubject)"

        var fields: [[String: Any]] = []

        if includePanelContext {
            fields.append([
                "name": "Panel context",
                "value": panelContextBlock().prefix(1024).description,
                "inline": false
            ])
        }

        if includeAppInfo {
            fields.append([
                "name": "Diagnostics",
                "value": appVersionLine,
                "inline": false
            ])
        }

        let embed: [String: Any] = [
            "title": title,
            "description": trimmedMessage,
            "fields": fields,
            "color": selectedType.embedColor,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "footer": ["text": "Searxly Knowledge Panel • \(selectedType.displayName)"]
        ]

        // Resolved per-build (Secrets.xcconfig → Info.plist, or env var). Public-source builds have
        // none — say so honestly instead of a bogus network error.
        guard let webhookURL = FeedbackWebhook.knowledgePanelURL else {
            sendError = FeedbackWebhook.notConfiguredMessage
            isSending = false
            return
        }

        do {
            var request = URLRequest(url: webhookURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["embeds": [embed]], options: [])

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(httpResponse.statusCode == 204 || (200...299).contains(httpResponse.statusCode)) {
                sendError = "Server error (\(httpResponse.statusCode)). Try copying the report instead."
            } else {
                sendSuccessMessage = "Your contribution was sent. Thank you for helping improve the panel."
                message = ""
            }
        } catch {
            sendError = error.localizedDescription
        }

        isSending = false
    }

    private func panelContextBlock() -> String {
        var lines: [String] = []
        lines.append("Query: \(content.query)")
        lines.append("Subject: \(panelSubject)")
        lines.append("Panel: \(panelKindLabel)")
        lines.append("Source: Grokipedia (direct fetch)")

        if case .entity(let data) = content.kind {
            if let kind = data.entityKind {
                lines.append("Entity kind: \(kind.rawValue)")
            }
            if let grok = data.grokipediaURL {
                lines.append("Grokipedia: \(grok)")
            }
            if let official = data.officialSiteURL {
                lines.append("Official site: \(official)")
            }
            if let preview = data.aboutParagraphs.first {
                lines.append("About preview: \(String(preview.prefix(280)))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func copyReportToClipboard() {
        var text = """
        Searxly Knowledge Panel Contribution
        Type: \(selectedType.displayName)
        Subject: \(panelSubject)

        \(message.trimmingCharacters(in: .whitespacesAndNewlines))

        """

        if includePanelContext {
            text += "\n--- Panel context ---\n\(panelContextBlock())\n"
        }
        if includeAppInfo {
            text += "\n--- Diagnostics ---\n\(appVersionLine)\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyMessage = "Copied to clipboard."

        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if copyMessage != nil { copyMessage = nil }
        }
    }
}
