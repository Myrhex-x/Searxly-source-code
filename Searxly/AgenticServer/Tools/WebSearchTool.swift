//
//  WebSearchTool.swift
//  Searxly — Agentic Tools
//
//  `web_search` — the core tool. Gives a user's local model private web access through the user's OWN
//  SearXNG instance. The query only ever reaches that instance; nothing goes to any AI provider.
//

import Foundation

@MainActor
struct WebSearchTool: AgenticTool {
    let id = "web_search"
    let summary = """
    Search the web privately through the user's own SearXNG instance and return titles, URLs, and \
    snippets. Use for facts, people, companies, products, current events, or any lookup. Optionally \
    scope to a category. The query only reaches the user's private search instance — nothing is sent \
    to any AI provider.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."],
            "category": [
                "type": "string",
                "enum": ["general", "news", "images", "videos", "science", "it", "files", "map", "music"],
                "description": "Optional. Scope results to a category. Defaults to a general web search."
            ]
        ],
        "required": ["query"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failed("Missing required argument 'query'.")
        }
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        let instances = browserState.searxInstances
        guard !instances.isEmpty else {
            return .failed("No SearXNG instance is configured in Searxly. Add one in Settings → SearXNG Instances.")
        }

        let rawCategory = (arguments["category"] as? String)?.lowercased()
        let category = (rawCategory == nil || rawCategory == "general") ? nil : rawCategory

        do {
            let (results, _) = try await SearXNGService.shared.searchWithFallback(
                query: query,
                categories: category,
                instances: instances,
                language: Localization.searchLanguageCode
            )
            guard !results.isEmpty else {
                return .ok("No results for \"\(query)\".")
            }
            return .ok(AgenticToolFormat.searchResults(results, query: query, limit: 8))
        } catch {
            return .failed("Search failed: \(error.localizedDescription)")
        }
    }
}

/// Shared, model-friendly formatting for tool output.
enum AgenticToolFormat {
    static func searchResults(_ results: [SearXNGResult], query: String, limit: Int) -> String {
        var lines: [String] = ["Private search results for \"\(query)\":", ""]
        for (i, r) in results.prefix(limit).enumerated() {
            var block = "\(i + 1). \(r.title)\n   \(r.url)"
            if let content = r.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
                block += "\n   \(content.prefix(240))"
            }
            lines.append(block)
        }
        return lines.joined(separator: "\n")
    }
}
