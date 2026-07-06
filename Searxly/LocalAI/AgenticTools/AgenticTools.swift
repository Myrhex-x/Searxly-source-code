//
//  AgenticTools.swift
//  Searxly
//
//  Assembler / entry point for the two canonical work tools (web_search + open_website).
//  The LocalAIChatSheet uses this to obtain the live bound Tool instances for the native
//  FoundationModels path, and also to obtain confirmation details and user-chip execution
//  helpers.
//
//  This replaces the previous monolithic 6-tool SearxlyTools + Actions/ system with a minimal,
//  per-tool-file organization that is easy to debug and evolve.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AgenticTools {

    // MARK: - Native Tool Construction (only when toolsEnabled + FoundationModels available)

    #if canImport(FoundationModels)
    /// Build the current (exactly two) tools bound to the live private implementations
    /// provided by the caller (ContentView → BrowserState closures + SearXNGService).
    @available(macOS 26.0, *)
    static func makeCurrent(
        webSearch: @escaping @Sendable (String) async -> String,
        openWebsite: @escaping @Sendable (String) async -> String,
        logToolUse: (@Sendable (String, String) -> Void)? = nil
    ) -> [any Tool] {
        [
            WebSearchTool(execute: webSearch, logUse: logToolUse),
            OpenWebsiteTool(execute: openWebsite, logUse: logToolUse)
        ]
    }
    #endif

    // MARK: - Marker / Legacy names (for parsers in the sheet)

    static let webSearchMarker = WebSearch.markerName
    static let openWebsiteMarker = OpenWebsite.markerName

    // MARK: - Confirmation card helpers (used by the sheet for both native-fallback and marker paths)

    static func confirmationDetails(for toolName: String, payload: String) -> (icon: String, headline: String, body: String, payloadLine: String, approveLabel: String) {
        let lower = toolName.lowercased()
        if lower == WebSearch.markerName || lower == "websearch" {
            return WebSearch.confirmationDetails(for: payload)
        } else if lower == OpenWebsite.markerName || lower == "open_site" {
            return OpenWebsite.confirmationDetails(for: payload)
        } else {
            // Fallback for anything unexpected after the prune
            return (
                "wrench.and.screwdriver",
                "Use a tool",
                "The assistant wants to use a local tool to help with this request.",
                payload,
                "Allow"
            )
        }
    }

    // MARK: - Explicit navigation command detection (used by the reliable direct "open ..." bypass in send())

    /// Canonical entry point for the early bypass + any other call site.
    /// Delegates to the hardened implementation in OpenWebsite (includes question/info-request rejection
    /// per Apple-style safeguards so that "can you open..." etc. never bypass the model/rules and trigger
    /// an unintended open_website with bad resolution).
    static func isExplicitNavigationCommand(_ text: String) -> Bool {
        OpenWebsite.isExplicitNavigationCommand(text)
    }
}
