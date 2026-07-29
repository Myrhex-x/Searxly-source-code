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
    let title = "Web search"
    let isReadOnly = true
    let summary = """
    Search the web privately through the user's own SearXNG instance and return titles, URLs, and \
    snippets. Use for facts, people, companies, products, current events, or any lookup. Optionally \
    scope to a category, limit freshness with time_range, or change how many results come back. The \
    query only reaches the user's private search instance — nothing is sent to any AI provider.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."],
            "category": [
                "type": "string",
                "enum": ["general", "news", "images", "videos", "science", "it", "files", "map", "music"],
                "description": "Optional. Scope results to a category. Defaults to a general web search."
            ],
            "time_range": [
                "type": "string",
                "enum": ["day", "week", "month", "year"],
                "description": "Optional. Only return results from the last day/week/month/year. Use for recent news or anything time-sensitive."
            ],
            "max_results": [
                "type": "integer",
                "minimum": 1,
                "maximum": 20,
                "description": "Optional. How many results to return (1–20). Default 8."
            ]
        ],
        "required": ["query"]
    ]

    /// Structured results for clients that can parse them (MCP `structuredContent`).
    let outputSchema: [String: Any]? = [
        "type": "object",
        "properties": [
            "query": ["type": "string"],
            "results": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "url": ["type": "string"],
                        "snippet": ["type": "string"]
                    ],
                    "required": ["title", "url"]
                ]
            ]
        ],
        "required": ["query", "results"]
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

        let validRanges: Set<String> = ["day", "week", "month", "year"]
        let timeRange = (arguments["time_range"] as? String)?.lowercased()
        let range = (timeRange.map { validRanges.contains($0) } == true) ? timeRange : nil

        let limit = min(max(AgenticToolFormat.intArg(arguments["max_results"]) ?? 8, 1), 20)

        do {
            let (results, _) = try await SearXNGService.shared.searchWithFallback(
                query: query,
                categories: category,
                instances: instances,
                language: Localization.searchLanguageCode,
                options: SearXNGSearchOptions(timeRange: range)
            )
            guard !results.isEmpty else {
                return .ok("No results for \"\(query)\".")
            }
            let text = AgenticToolFormat.searchResults(results, query: query, limit: limit)
            let structured: [String: Any] = [
                "query": query,
                "results": results.prefix(limit).map { r -> [String: Any] in
                    var item: [String: Any] = ["title": r.title, "url": r.url]
                    if let c = r.content?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                        item["snippet"] = String(c.prefix(400))
                    }
                    return item
                }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: structured) {
                return .okStructured(text: text, structuredJSON: data)
            }
            return .ok(text)
        } catch {
            return .failed("Search failed: \(error.localizedDescription)")
        }
    }
}

/// Shared, model-friendly formatting + argument parsing for tool output.
enum AgenticToolFormat {
    /// Lenient integer parsing — small local models send numbers as Int, Double, or String.
    static func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

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
