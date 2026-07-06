//
//  SERPSourcePolicy.swift
//  Searxly
//
//  Grokipedia-first / Wikipedia-suppressed ranking for native web SERP.
//  Wikipedia remains available for explicit wiki queries and knowledge-panel enrichment.
//

import Foundation

enum SERPSourcePolicy {

    // MARK: - Host detection

    static func isGrokipedia(_ result: SearXNGResult) -> Bool {
        guard let host = URL(string: result.url)?.host?.lowercased() else {
            return result.url.lowercased().contains("grokipedia")
        }
        return host.contains("grokipedia")
    }

    static func isWikipedia(_ result: SearXNGResult) -> Bool {
        guard let host = URL(string: result.url)?.host?.lowercased() else { return false }
        return host.contains("wikipedia.org")
    }

    /// User intentionally asked for Wikipedia (navigation or research on that site).
    static func isExplicitWikipediaQuery(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        if lower.contains("wikipedia") { return true }
        if lower.contains("site:wikipedia") || lower.contains("site:en.wikipedia") { return true }
        if lower.contains("wikipedia.org") { return true }

        let wikiPhrases = ["wikipedia page for", "the wikipedia page for", "wiki page for", "wiki for "]
        if wikiPhrases.contains(where: { lower.contains($0) }) { return true }

        if OfficialEntityDatabase.entity(for: lower)?.canonicalKey == "wikipedia" { return true }
        if lower == "wiki" || lower == "wikipedia" { return true }

        return false
    }

    // MARK: - Post-rank adjustments (single-pass combined policy)

    /// Single-pass replacement for the three separate passes (prioritize Grokipedia,
    /// promote best Grokipedia to top, suppress Wikipedia). Eliminates 3 array allocations
    /// and repeated per-result URL parsing.
    static func applyAll(_ results: [SearXNGResult], query: String) -> [SearXNGResult] {
        guard !results.isEmpty else { return results }
        let skipSuppression = isExplicitWikipediaQuery(query)
        let subject = normalizedSubject(from: query)

        var grokItems: [SearXNGResult] = []
        var bestGrokScore = -1
        var bestGrokListIndex = 0
        var otherItems: [SearXNGResult] = []

        for r in results {
            if isGrokipedia(r) {
                let score = grokipediaRelevanceScore(r, subject: subject)
                if score > bestGrokScore {
                    bestGrokScore = score
                    bestGrokListIndex = grokItems.count
                }
                grokItems.append(r)
            } else if skipSuppression || !isWikipedia(r) {
                otherItems.append(r)
            }
            // Wikipedia dropped when !skipSuppression
        }

        guard !grokItems.isEmpty else { return otherItems }

        // Best-scored Grokipedia result goes first; rest follow in original order
        if bestGrokListIndex > 0 {
            let best = grokItems.remove(at: bestGrokListIndex)
            grokItems.insert(best, at: 0)
        }
        return grokItems + otherItems
    }

    // Individual methods kept for external callers (ranker bonus, tests, etc.)

    /// Moves all Grokipedia hits to the top (stable relative order).
    static func prioritizeGrokipedia(_ results: [SearXNGResult]) -> [SearXNGResult] {
        let grok = results.filter { isGrokipedia($0) }
        guard !grok.isEmpty else { return results }
        let other = results.filter { !isGrokipedia($0) }
        return grok + other
    }

    /// Promotes the best Grokipedia page match to index 0 when one exists.
    static func promoteBestGrokipediaToTop(_ results: [SearXNGResult], query: String) -> [SearXNGResult] {
        guard !results.isEmpty else { return results }
        let subject = normalizedSubject(from: query)
        let grokHits = results.enumerated().filter { isGrokipedia($0.element) }
        guard !grokHits.isEmpty else { return results }
        let bestIndex = grokHits.max { a, b in
            grokipediaRelevanceScore(a.element, subject: subject) < grokipediaRelevanceScore(b.element, subject: subject)
        }?.offset
        guard let idx = bestIndex, idx > 0 else { return results }
        var copy = results
        let promoted = copy.remove(at: idx)
        copy.insert(promoted, at: 0)
        return copy
    }

    /// Hides Wikipedia from the flat SERP unless the user explicitly searched for it.
    static func suppressWikipedia(_ results: [SearXNGResult], query: String) -> [SearXNGResult] {
        guard !isExplicitWikipediaQuery(query) else { return results }
        return results.filter { !isWikipedia($0) }
    }

    // MARK: - Ranker scoring helpers

    /// Score bump comparable to the old Wikipedia-engine prominence in SearXNG.
    static func grokipediaRankingBonus(
        result: SearXNGResult,
        query: String,
        intent: SearchResultRanker.QueryIntent
    ) -> Int {
        guard isGrokipedia(result) else { return 0 }

        var bonus = 0
        switch intent {
        case .informational: bonus += 42
        case .general: bonus += 34
        case .navigational: bonus += 26
        }

        if result.url.lowercased().contains("/page/") {
            bonus += 14
        }

        let subject = normalizedSubject(from: query)
        bonus += min(grokipediaRelevanceScore(result, subject: subject), 24)

        if result.engine?.lowercased().contains("wikipedia") == true {
            bonus += 6
        }

        return bonus
    }

    static func wikipediaRankingPenalty(query: String) -> Int {
        isExplicitWikipediaQuery(query) ? 0 : 55
    }

    // MARK: - Private

    private static func normalizedSubject(from query: String) -> String {
        var s = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["who is ", "who's ", "who was ", "what is ", "what's ", "tell me about "]
        for p in prefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func grokipediaRelevanceScore(_ result: SearXNGResult, subject: String) -> Int {
        guard !subject.isEmpty else { return 0 }

        let title = result.title.lowercased()
        let url = result.url.lowercased()
        let slug = url.components(separatedBy: "/page/").last?
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ") ?? ""

        var score = 0
        if title.contains(subject) || slug.contains(subject) { score += 12 }
        if slug == subject || title == subject { score += 18 }

        let subjectTokens = Set(subject.split(separator: " ").map(String.init).filter { $0.count > 1 })
        for token in subjectTokens where title.contains(token) || slug.contains(token) {
            score += 4
        }

        return score
    }
}