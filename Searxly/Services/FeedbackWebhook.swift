//
//  FeedbackWebhook.swift
//  Searxly
//
//  Resolves the Discord webhook both feedback surfaces post to (Settings → Feedback, and the
//  knowledge panel's contribution sheet). Follows the SearxlyGateway pattern exactly: the value is
//  a per-build secret — blank in the public source, layered in from the gitignored Secrets.xcconfig
//  via the SearxlyFeedbackWebhook Info.plist key, or the SEARXLY_FEEDBACK_WEBHOOK env var for dev.
//
//  ⚠️ xcconfig gotcha: "//" starts a comment INSIDE VALUES, so a full "https://discord.com/…" pasted
//  into Secrets.xcconfig silently truncates to "https:". The convention here is therefore to store
//  the webhook WITHOUT the scheme ("discord.com/api/webhooks/…"); `url` adds https:// itself (and
//  accepts a full URL too, for the env-var path).
//

import Foundation

enum FeedbackWebhook {

    /// Settings → Feedback channel (env `SEARXLY_FEEDBACK_WEBHOOK` / plist `SearxlyFeedbackWebhook`).
    nonisolated static var settingsURL: URL? {
        resolve(env: "SEARXLY_FEEDBACK_WEBHOOK", plistKey: "SearxlyFeedbackWebhook")
    }

    /// Knowledge-panel contributions channel — a SEPARATE Discord channel from general feedback
    /// (env `SEARXLY_KNOWLEDGE_WEBHOOK` / plist `SearxlyKnowledgeWebhook`).
    nonisolated static var knowledgePanelURL: URL? {
        resolve(env: "SEARXLY_KNOWLEDGE_WEBHOOK", plistKey: "SearxlyKnowledgeWebhook")
    }

    /// The user-facing explanation when direct send isn't available in this build.
    nonisolated static let notConfiguredMessage =
        "Direct send isn't set up in this build. Use \"Copy to clipboard\" and open a GitHub issue instead."

    /// Env var (dev) → Info.plist (build-time from Secrets.xcconfig) → nil. Always https; a
    /// scheme-less stored value gets the scheme added here (see header for the xcconfig reason).
    nonisolated private static func resolve(env: String, plistKey: String) -> URL? {
        var value = ProcessInfo.processInfo.environment[env]
            ?? (Bundle.main.object(forInfoDictionaryKey: plistKey) as? String)
            ?? ""
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }
}
