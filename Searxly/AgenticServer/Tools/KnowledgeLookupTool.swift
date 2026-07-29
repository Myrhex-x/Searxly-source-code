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
    let title = "Knowledge lookup"
    let isReadOnly = true
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

    var outputSchema: [String: Any]? {
        ["type": "object", "properties": [
            "name": ["type": "string"],
            "description": ["type": "string"],
            "official_site": ["type": "string"],
            "facts": ["type": "array", "items": ["type": "object", "properties": [
                "label": ["type": "string"], "value": ["type": "string"]
            ]]]
        ]]
    }

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

        let structured: [String: Any] = [
            "name": entity.title,
            "description": entity.aboutParagraphs.prefix(3).joined(separator: "\n\n"),
            "official_site": entity.officialSiteURL.map { "\($0)" } ?? "",
            "facts": entity.facts.prefix(10).map { ["label": $0.label, "value": $0.value] }
        ]
        return .okStructured(text: lines.joined(separator: "\n"),
                             structuredJSON: (try? JSONSerialization.data(withJSONObject: structured)) ?? Data("{}".utf8))
    }
}
