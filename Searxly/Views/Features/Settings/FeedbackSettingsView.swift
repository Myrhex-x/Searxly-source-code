//
//  FeedbackSettingsView.swift
//  Searxly
//

import SwiftUI
import Foundation

struct FeedbackSettingsView: View {
    @Binding var searxInstances: [SearXNGInstance]
    @Binding var currentInstanceID: UUID

    @State private var selectedType: FeedbackType = .general
    @State private var reportTitle: String = ""
    @State private var reportDescription: String = ""
    @State private var includeAppInfo: Bool = true
    @State private var includeInstance: Bool = true

    @State private var isSending = false
    @State private var sendSuccessMessage: String? = nil
    @State private var sendError: String? = nil
    @State private var copyMessage: String? = nil

    private static let discordWebhookURL = "INPUT"

    private enum FeedbackType: String, CaseIterable {
        case bug, suggestion, general, other

        var displayName: String {
            switch self {
            case .bug:        return "Bug"
            case .suggestion: return "Feature idea"
            case .general:    return "General"
            case .other:      return "Other"
            }
        }

        var shortLabel: String {
            switch self {
            case .bug: return "BUG"
            case .suggestion: return "IDEA"
            case .general: return "FEEDBACK"
            case .other: return "OTHER"
            }
        }
    }

    private var currentInstance: SearXNGInstance? {
        searxInstances.first { $0.id == currentInstanceID }
    }

    private var canSend: Bool {
        !reportDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        SettingsPane {
            SettingsPaneHeader(
                title: "Feedback",
                subtitle: "Tell us what is broken or what you would like to see. Sent directly to the team."
            )

            SettingsSection(title: "Message") {
                Picker("Type", selection: $selectedType) {
                    ForEach(FeedbackType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                SettingsDivider()

                TextField("Subject (optional)", text: $reportTitle)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Details")
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $reportDescription)
                        .font(.body)
                        .frame(minHeight: 120, maxHeight: 180)
                        .padding(8)
                        .background(.quaternary.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    Text("Required. For bugs, include steps to reproduce.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "Attach info") {
                SettingsToggleRow(
                    title: "App and macOS version",
                    isOn: $includeAppInfo
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Active search instance",
                    description: currentInstance.map { $0.displayName + " — " + $0.url } ?? "None configured",
                    isOn: $includeInstance
                )
            }

            Button {
                Task { await sendFeedback() }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().controlSize(.small)
                        Text("Sending…")
                    } else {
                        Text("Send")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .disabled(!canSend)

            if let success = sendSuccessMessage {
                SettingsCallout(title: "Thanks!", message: success, tint: .green, systemImage: "checkmark.circle.fill")
            }

            if let error = sendError {
                SettingsCallout(title: "Could not send", message: error, tint: .orange, systemImage: "exclamationmark.triangle.fill")
            }

            if let copyMsg = copyMessage {
                Text(copyMsg).font(.caption).foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                Button("Copy to clipboard") { copyReportToClipboard() }
                    .buttonStyle(.link)
                Text("•").foregroundStyle(.tertiary)
                Link("Open GitHub issues", destination: URL(string: "https://github.com/Myrhex-x/Searxly/issues")!)
            }
            .font(.callout)
        }
        .onChange(of: reportDescription) { _, _ in
            if sendSuccessMessage != nil || sendError != nil {
                sendSuccessMessage = nil
                sendError = nil
            }
        }
    }

    private func sendFeedback() async {
        guard canSend else { return }

        isSending = true
        sendSuccessMessage = nil
        sendError = nil
        copyMessage = nil

        let effectiveTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(selectedType.shortLabel): \(String(reportDescription.prefix(60)))"
            : reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedDescription = reportDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        var diagnosticsLines: [String] = []
        if includeAppInfo {
            let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            diagnosticsLines.append("App: v\(shortVer) (build \(build))")
            diagnosticsLines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
        if includeInstance, let inst = currentInstance {
            diagnosticsLines.append("Instance: \(inst.displayName) — \(inst.url)")
        }

        let embed: [String: Any] = [
            "title": "[\(selectedType.shortLabel)] \(effectiveTitle)",
            "description": trimmedDescription,
            "fields": diagnosticsLines.isEmpty ? [] : [[
                "name": "Diagnostics",
                "value": diagnosticsLines.joined(separator: "\n"),
                "inline": false
            ]],
            "color": 0x22C55E,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "footer": ["text": "Searxly Feedback • \(selectedType.displayName)"]
        ]

        guard let webhookURL = URL(string: Self.discordWebhookURL) else {
            sendError = "Could not reach the feedback service."
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
                sendSuccessMessage = "Your message was sent."
            }
        } catch {
            sendError = error.localizedDescription
        }

        isSending = false
    }

    private func copyReportToClipboard() {
        let effectiveTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(selectedType.shortLabel): \(String(reportDescription.prefix(60)))"
            : reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        var text = """
        Searxly Feedback
        Type: \(selectedType.displayName)
        Subject: \(effectiveTitle)

        \(reportDescription.trimmingCharacters(in: .whitespacesAndNewlines))

        """

        if includeAppInfo {
            let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            text += "App: v\(shortVer) (build \(build))\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        }
        if includeInstance, let inst = currentInstance {
            text += "Instance: \(inst.displayName) — \(inst.url)\n"
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
