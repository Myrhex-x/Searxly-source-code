//
//  KnowledgeLookupTool.swift
//  Searxly — Agentic Tools
//
//  `knowledge_lookup` — a structured fact card for a well-known entity, sourced from the user's private
//  search + Searxly's knowledge providers. Handy when the model wants a quick, grounded summary instead
//  of parsing raw search results.
//

import Foundation

@MainActor
struct KnowledgeLookupTool: AgenticTool {
    let id = "knowledge_lookup"
    let summary = """
    Get a structured fact card for a well-known person, company, place, or thing — a short description, \
    the official site, and key facts. Sourced from the user's private search and knowledge providers.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The entity to look up (a person, company, place, or thing)."]
        ],
        "required": ["query"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failed("Missing required argument 'query'.")
        }
        let instanceURL = AgenticServerManager.shared.browserState?.currentSearxInstance.url
        guard let content = await KnowledgePanelService.resolve(query: query, imageInstanceURL: instanceURL),
              case let .entity(entity) = content.kind else {
            return .failed("No knowledge card found for \"\(query)\".")
        }

        var lines: [String] = [entity.title]
        if !entity.aboutParagraphs.isEmpty {
            lines.append("")
            lines.append(entity.aboutParagraphs.prefix(3).joined(separator: "\n\n"))
        }
        if let site = entity.officialSiteURL {
            lines.append("")
            lines.append("Official site: \(site)")
        }
        if !entity.facts.isEmpty {
            lines.append("")
            lines.append("Key facts:")
            for fact in entity.facts.prefix(10) {
                lines.append("- \(fact.label): \(fact.value)")
            }
        }
        return .ok(lines.joined(separator: "\n"))
    }
}
