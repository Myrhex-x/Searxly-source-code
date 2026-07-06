//
//  WebSearchTool.swift
//  Searxly
//
//  One of the two canonical work tools for the Local AI on-device system (post 2026-06 minimal-tool rework).
//
//  Purpose:
//  - The ONLY research / information tool.
//  - For any "who is", "tell me about", facts, current events, people, companies, science, tech, "what is X?" etc.
//  - Always routes exclusively through the user's private/local SearXNG instance(s).
//  - Results are returned so the model (or follow-up generation) can synthesize a natural, grounded answer **inside the chat**.
//  - Never used for navigation / "open the page" intents (those go to OpenWebsiteTool only).
//
//  This file owns everything specific to web_search so bugs, prompt tweaks, formatting, and the native Tool
//  definition can be worked on in isolation.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Native Foundation Models Tool Support (when toolsEnabled)

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
struct WebSearchArgs {
    @Guide(description: "The exact search query to send to the user's private SearXNG instance(s). Use the user's words or refine slightly for better results on people/companies/events/facts.")
    var query: String
}

@available(macOS 26.0, *)
struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Perform a private web search using ONLY the user's own configured local or self-hosted SearXNG instance(s). Use this for almost any informational, factual, knowledge, or explanatory question (examples: 'who is Elon Musk?', 'Elon Musk Terafab chip facility', 'latest Tesla', 'what is Rust borrow checker?', 'browse and tell me about X', current events, biographies). Never uses public instances. You will receive titles + URLs + short snippets — read them and synthesize a direct, natural, to-the-point answer **in the chat**. Do NOT use numbers, [1], [N], citations, or a sources list. Just give the answer using the info. Do NOT use for explicit navigation ('open the official site', 'go to x.com') — use open_website only for those."

    typealias Arguments = WebSearchArgs

    private let execute: @Sendable (String) async -> String
    private let logUse: (@Sendable (String, String) -> Void)?

    init(execute: @escaping @Sendable (String) async -> String, logUse: (@Sendable (String, String) -> Void)? = nil) {
        self.execute = execute
        self.logUse = logUse
    }

    func call(arguments: Arguments) async throws -> String {
        logUse?("web_search", arguments.query)
        return await execute(arguments.query)
    }
}

#endif

// MARK: - User-called execution (primary "Web search" chip / explicit button path)

enum WebSearch {

    /// The canonical name used in legacy TOOL_REQUEST: markers and bare-tool detection.
    static let markerName = "web_search"

    /// Compact result block for injection after a user-invoked or confirmed web_search.
    /// The model (in runFollowUpGeneration) will turn this into a friendly chat answer.
    static func execute(
        query: String,
        using performPrivateSearch: ((String) async -> [SearXNGResult])?
    ) async -> String {
        guard let perform = performPrivateSearch, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Web search is not available right now (no private SearXNG instance configured)."
        }
        let results = await perform(query)
        guard !results.isEmpty else {
            return "Private web search for \"\(query)\" returned no results."
        }
        // Provide search results as clean, unnumbered context so the model can synthesize a direct, natural answer
        // without any citation markers or numbering. Go straight to the point using the info.
        let top = results.prefix(6)
        var lines: [String] = ["Fresh private search results for \"\(query)\":"]
        for r in top {
            let title = r.title
            let url = r.url
            let snip = (r.content ?? "").prefix(220)
            lines.append("Title: \(title)\nURL: \(url)\nSnippet: \(snip)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Details for the confirmation card (shown on marker path or when toolsEnabled==false).
    static func confirmationDetails(for payload: String) -> (icon: String, headline: String, body: String, payloadLine: String, approveLabel: String) {
        (
            "magnifyingglass",
            "I’d like to do a quick private web search",
            "To give you a better answer for this, I can use **your local SearXNG instance** to search the web (the query goes only to your instance, results come straight back to me).",
            "Query: “\(payload)”",
            "Go ahead & search"
        )
    }
}
