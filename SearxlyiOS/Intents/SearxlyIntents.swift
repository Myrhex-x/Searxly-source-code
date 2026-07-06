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
    var pendingSearch: String?
    var pendingPrivateTab = false
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
    static let title: LocalizedStringResource = "Open Private Tab"
    static let description = IntentDescription("Open a new private tab in Searxly.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pendingPrivateTab = true
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
                "Open a private tab in \(.applicationName)",
                "New private tab in \(.applicationName)",
            ],
            shortTitle: "Private Tab",
            systemImageName: "hand.raised"
        )
    }
}
