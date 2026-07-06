//
//  KnowledgeQueryDetector.swift
//  Searxly
//
//  Shared heuristics for knowledge-panel eligibility and Grokipedia SERP boosting.
//

import Foundation

enum KnowledgeQueryKind: Equatable {
    case entity
    case dictionary
    case none
}

enum KnowledgeQueryDetector {

    static func classify(_ query: String) -> KnowledgeQueryKind {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if looksLikeURLInput(trimmed) { return .none }

        let normalized = normalizedQuery(trimmed)
        let tokens = tokenize(normalized)
        guard !tokens.isEmpty, tokens.count <= 5 else { return .none }

        if isDictionaryCandidate(normalized, tokens: tokens) {
            return .dictionary
        }

        if isEntityCandidate(normalized, tokens: tokens) {
            return .entity
        }

        return .none
    }

    /// Whether Grokipedia hits should be bubbled to the top of web SERP results.
    static func shouldBoostGrokipedia(_ query: String) -> Bool {
        classify(query) == .entity
    }

    // MARK: - Entity

    private static func isEntityCandidate(_ normalized: String, tokens: [String]) -> Bool {
        if OfficialEntityDatabase.entity(for: normalized) != nil {
            return true
        }

        // Any query with an explicit Grokipedia slug is a known entity.
        if GrokipediaSlugCatalog.hasExplicitSlug(for: normalized) {
            return true
        }

        if normalized.contains("who is") || normalized.contains("who's") || normalized.contains("who was") ||
           normalized.contains("what is") || normalized.contains("what's") ||
           normalized.contains("tell me about") {
            return true
        }

        guard tokens.count >= 1, tokens.count <= 4 else { return false }

        let skipWords = ["how", "why", "when", "where", "best", "top", "buy", "price", "review", "tutorial", "guide", "vs", "versus"]
        if tokens.contains(where: { skipWords.contains($0) }) { return false }

        return tokens.allSatisfy { token in
            token.rangeOfCharacter(from: .letters) != nil &&
            token.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "&" }
        }
    }

    // MARK: - Dictionary

    private static func isDictionaryCandidate(_ normalized: String, tokens: [String]) -> Bool {
        guard tokens.count == 1, let word = tokens.first else { return false }
        guard word.count >= 2, word.count <= 24 else { return false }
        guard word.allSatisfy({ $0.isLetter || $0 == "-" }) else { return false }

        // Known brands / entities should show the entity card, not a dictionary entry. Use only exact
        // lookups here — the loose `fuzzyMatchURL` mis-flags common words ("site", "maps", "ai") as
        // brands, which is both wrong and pointless now that entity resolution is relevance-gated.
        if OfficialEntityDatabase.entity(for: word) != nil { return false }
        // Any word with an explicit curated Grokipedia slug is a brand/entity, not a dictionary word.
        if GrokipediaSlugCatalog.hasExplicitSlug(for: word) { return false }

        return true
    }

    // MARK: - Helpers

    private static func normalizedQuery(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 '&-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenize(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private static func looksLikeURLInput(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.contains(".") && !lower.contains(" ") { return true }
        return false
    }
}