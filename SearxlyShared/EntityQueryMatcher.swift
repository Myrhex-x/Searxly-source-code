//
//  EntityQueryMatcher.swift
//  Searxly
//
//  Strict query → curated-entity resolution shared by the native SERP ranker (both platforms)
//  and the macOS knowledge panel. Extracted from KnowledgePanelService so the ranking pipeline
//  can live in SearxlyShared without dragging the whole panel service along.
//
//  Only a strong (exact canonical/alias) match resolves. We deliberately do NOT use
//  `OfficialEntityDatabase.fuzzyMatchURL` here — that matcher is tuned for the agent's
//  "open website" navigation, where a loose best-guess is acceptable. Ranking and knowledge
//  cards must only anchor an entity when we are confident the query *is* the entity.
//

import Foundation

enum EntityQueryMatcher {

    /// Resolves the query to a curated entity via exact canonical/alias match only
    /// (after stripping question prefixes and noise words like "official"/"site").
    static func bestEntity(for query: String) -> OfficialEntityDatabase.OfficialEntity? {
        let subject = strippedSubject(from: query)
        if let entity = OfficialEntityDatabase.entity(for: subject) {
            return entity
        }

        // Retry against the subject with trailing/leading noise words removed
        // ("apple official site" → "apple", "the tesla site" → "tesla").
        let cleaned = significantTokens(subject).joined(separator: " ")
        if !cleaned.isEmpty, cleaned != subject,
           let entity = OfficialEntityDatabase.entity(for: cleaned) {
            return entity
        }

        return nil
    }

    /// The query with leading question phrasing removed ("who is elon musk" → "elon musk").
    static func strippedSubject(from query: String) -> String {
        var s = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["who is ", "who's ", "who was ", "what is ", "what's ", "tell me about "]
        for p in prefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that carry no entity-identity signal, stripped before comparing a query to an entity
    /// or article.
    static let relevanceNoiseWords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "for", "to", "in", "on", "at", "by",
        "is", "are", "was", "were", "be", "vs",
        "official", "site", "website", "homepage", "home", "page",
        "company", "co", "inc", "corp", "ltd", "llc", "plc", "group",
        "wiki", "wikipedia"
    ]

    /// Lowercased, punctuation-free, noise-word-free tokens. Used for both query subjects and
    /// article titles/slugs so they can be compared on equal footing.
    static func significantTokens(_ string: String) -> [String] {
        string.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !relevanceNoiseWords.contains($0) }
    }
}
