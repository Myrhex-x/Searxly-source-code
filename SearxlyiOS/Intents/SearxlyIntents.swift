//
//  SearxlyIntents.swift
//  SearxlyiOS
//
//  App Intents — private ecosystem reach WITHOUT extra targets or data leaving the device.
//  These surface in Siri, Spotlight, and the Shortcuts app: "Search Searxly for …" and
//  "Open a private tab." They just hand an action to the running app via IntentRouter; the
//  browser performs it. No analytics, no donation of query contents beyond what iOS needs to
//  run the shortcut the user explicitly invoked.
//

import AppIntents
import Observation

/// Bridges an invoked intent into the live browser UI (consumed by BrowserView).
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()
    /// A specific query to run in a fresh tab (Siri "Search with Searxly", Spotlight).
    var pendingSearch: String?
    /// Open a new private tab (Siri / quick action).
    var pendingPrivateTab = false
    /// Quick action "New Search": fresh tab with the address bar focused, no query yet.
    var pendingNewSearch = false
    /// Reopen the most recently closed tab (Siri / quick action).
    var pendingReopenLast = false
    /// Open a specific URL (Spotlight bookmark tap, deep link).
    var pendingURL: URL?
    /// Show the Downloads sheet (Siri).
    var pendingDownloads = false
    /// Summarize the page in the active tab with on-device intelligence (Siri / Shortcuts).
    var pendingSummarize = false
    private init() {}
}

struct SearchSearxlyIntent: AppIntent {
    static let title: LocalizedStringResource = "Search with Searxly"
    static let description = IntentDescription("Run a private search in Searxly.")
    static let openAppWhenRun = true

    @Parameter(title: "Search", requestValueDialog: "What would you like to search?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingSearch = query
        return .result()
    }
}

struct OpenPrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Enter Private Mode"
    static let description = IntentDescription("Switch Searxly into Private Mode.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingPrivateTab = true
        return .result()
    }
}

struct ReopenLastTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Reopen Last Tab"
    static let description = IntentDescription("Reopen the most recently closed tab in Searxly.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingReopenLast = true
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Downloads"
    static let description = IntentDescription("Show your downloads in Searxly.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingDownloads = true
        return .result()
    }
}

struct SummarizeCurrentPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Current Page"
    static let description = IntentDescription("Summarize the page open in Searxly with on-device intelligence — the page never leaves your device.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingSummarize = true
        return .result()
    }
}

struct SearxlyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchSearxlyIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Private search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenPrivateTabIntent(),
            phrases: [
                "Turn on Private Mode in \(.applicationName)",
                "Private Mode in \(.applicationName)",
            ],
            shortTitle: "Private Mode",
            systemImageName: "hand.raised.fill"
        )
        AppShortcut(
            intent: ReopenLastTabIntent(),
            phrases: [
                "Reopen last tab in \(.applicationName)",
                "Reopen my last \(.applicationName) tab",
            ],
            shortTitle: "Reopen Tab",
            systemImageName: "arrow.uturn.left"
        )
        AppShortcut(
            intent: OpenDownloadsIntent(),
            phrases: [
                "Open downloads in \(.applicationName)",
                "Show my \(.applicationName) downloads",
            ],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: SummarizeCurrentPageIntent(),
            phrases: [
                "Summarize this page in \(.applicationName)",
                "Summarize my \(.applicationName) page",
            ],
            shortTitle: "Summarize",
            systemImageName: "apple.intelligence"
        )
    }
}
