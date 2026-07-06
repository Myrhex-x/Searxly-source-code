//
//  AIFeatures.swift
//  Searxly
//
//  Feature flags for the AI program. Mirrors ExtensionFeatures: one release kill switch that
//  makes the whole feature invisible and inert until it's ready to ship.
//

import Foundation

enum AIFeatures {
    /// RELEASE KILL SWITCH for ALL AI in Searxly — on-device chat, Searxly AI cloud, Summarize
    /// Page, quick answers (Explain/Summarize from selection), the web-page context-menu items,
    /// the ⌘⌥A menu command, the home-hero chat button, and both AI Settings panes.
    ///
    /// While `false`, LocalIntelligenceManager reports itself disabled (all AI work no-ops),
    /// and every entry point above is hidden — users cannot reach AI at all. User preferences
    /// (master toggle, chat history opt-ins) are left untouched on disk, so flipping this to
    /// `true` restores whatever the user had configured.
    static let programEnabled = false
}
