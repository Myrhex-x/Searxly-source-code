//
//  SearchResultRanker.swift
//  Searxly
//
//  Client-side re-ranking for web/news native SERP (2026-06 rework v2).
//  Skipped entirely for images/videos (handled by SearchResultProcessor).
//

import Foundation

enum SearchResultRanker {

    enum QueryIntent {
        case navigational
        case informational
        case general
    }

    static func reranked(
        _ results: [SearXNGResult],
        query: String,
        category: String?
    ) -> [SearXNGResult] {
        if category == "images" || category == "videos" { return results }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !results.isEmpty else { return results }

        let q = normalizedQuery(trimmed)
        let qTokens = tokenSet(from: q)
        let intent = detectIntent(q, tokens: qTokens)
        let isNews = (category == "news")
        let authority = OfficialEntityDatabase.authorityHosts()

        let scored: [(result: SearXNGResult, score: Int, originalIndex: Int)] = results.enumerated().map { (idx, r) in
            let score = scoreResult(
                result: r,
                query: q,
                queryTokens: qTokens,
                intent: intent,
                authorityHosts: authority,
                isNewsCategory: isNews
            )
            return (r, score, idx)
        }

        let sorted = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.originalIndex < b.originalIndex
        }

        var ranked = sorted.map { $0.result }

        if intent == .navigational {
            ranked = applyOfficialHostPromotion(ranked, query: q, authorityHosts: authority)
        }

        return ranked
    }

    // MARK: - Scoring

    private static func scoreResult(
        result: SearXNGResult,
        query: String,
        queryTokens: Set<String>,
        intent: QueryIntent,
        authorityHosts: Set<String>,
        isNewsCategory: Bool
    ) -> Int {
        var score = 0

        // Parse URL once; reuse parsed components for both host and path below
        let parsedURL = URL(string: result.url)
        let host = (parsedURL?.host ?? result.url).lowercased()
        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
        let title = result.title.lowercased()
        let snippet = (result.content ?? "").lowercased()

        for t in queryTokens where t.count > 1 {
            if cleanHost.contains(t) || title.contains(t) { score += 3 }
            if host.contains(t) || title.contains(t) { score += 2 }
            if snippet.contains(t) { score += 2 }
        }

        // Whether the query is actually ABOUT this host. The official-site bonuses below must only
        // apply to a relevant host — otherwise every known brand (x.com, tesla.com, …) floats to the
        // top of unrelated navigational searches (the "torproject → x.com" bug).
        let hostLabel = cleanHost.split(separator: ".").first.map(String.init) ?? cleanHost
        let joinedTokens = queryTokens.joined()
        let hostRelevant =
            queryTokens.contains { $0.count > 1 && cleanHost.contains($0) }
            || (hostLabel.count > 1 && !joinedTokens.isEmpty && (joinedTokens.contains(hostLabel) || hostLabel.contains(joinedTokens)))

        if intent == .navigational, queryTokens.count <= 3 {
            if !joinedTokens.isEmpty, cleanHost.contains(joinedTokens) || cleanHost == joinedTokens { score += 12 }
            // Exact official-domain match (e.g. "torproject" → torproject.org) — strongly favored so
            // the real site beats unrelated big brands.
            if hostLabel == joinedTokens && !joinedTokens.isEmpty { score += 16 }
        }

        if hostRelevant, authorityHosts.contains(cleanHost) || authorityHosts.contains(host) {
            score += intent == .navigational ? 32 : 18
        }
        if hostRelevant, cleanHost.contains("terafab.ai") || cleanHost.contains("x.ai") || cleanHost.contains("tesla.com") {
            score += intent == .navigational ? 20 : 8
        }

        if title.contains("official") || title.contains("home") || title.contains("homepage") {
            score += 9
        }

        let path = (parsedURL?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path.count <= 8 {
            score += 7
        } else if path.split(separator: "/").count >= 3 {
            score -= 4
        }

        if result.url.hasPrefix("https") { score += 1 }

        if !snippet.isEmpty {
            score += 4
            let overlap = queryTokens.filter { snippet.contains($0) }.count
            score += min(overlap * 2, 8)
        } else if intent == .informational {
            score -= 3
        }

        if isNewsCategory, let pub = result.formattedPublishedDate(), pub.count <= 16 {
            score += 4
        }

        if intent == .navigational {
            let newsHosts = [
                "teslarati", "cnbc", "bbc", "nytimes", "reuters", "bloomberg", "forbes",
                "gizmodo", "techcrunch", "theverge", "arstechnica", "wired", "engadget"
            ]
            for nh in newsHosts where cleanHost.contains(nh) {
                score -= 12
                break
            }
            if title.contains("news") && !title.contains("official") {
                score -= 5
            }
            // Aggregator/platform sites are rarely the official destination for a brand query.
            // e.g. searching "roblox" should surface roblox.com, not youtube.com/watch?...
            let aggregatorHosts = [
                "youtube", "youtu.be", "reddit", "instagram", "facebook", "tiktok",
                "twitter", "twitch", "vimeo", "dailymotion", "pinterest", "tumblr"
            ]
            for agg in aggregatorHosts where cleanHost.contains(agg) {
                score -= 22
                break
            }
        }

        if title.count > 140 || cleanHost.split(separator: ".").count > 4 {
            score -= 2
        }

        score += SERPSourcePolicy.grokipediaRankingBonus(result: result, query: query, intent: intent)

        if cleanHost.contains("wikipedia.org") {
            score -= SERPSourcePolicy.wikipediaRankingPenalty(query: query)
        }

        return max(0, score)
    }

    private static func applyOfficialHostPromotion(
        _ results: [SearXNGResult],
        query: String,
        authorityHosts: Set<String>
    ) -> [SearXNGResult] {
        let q = query.lowercased()
        guard detectIntent(q, tokens: tokenSet(from: q)) == .navigational else { return results }

        var bestOfficialIndex: Int?
        var bestOfficialScore = -1

        for (i, r) in results.enumerated() {
            let h = (URL(string: r.url)?.host ?? r.url).lowercased().replacingOccurrences(of: "www.", with: "")
            var s = 0
            if authorityHosts.contains(h) { s += 30 }
            if h.contains("terafab.ai") || h.contains("x.ai") || h.contains("tesla.com") { s += 20 }
            if q.contains("terafab") && h.contains("terafab") { s += 50 }
            if (q == "x" || q.contains("twitter")) && h.contains("x.com") { s += 40 }
            if s > bestOfficialScore && s > 30 {
                bestOfficialScore = s
                bestOfficialIndex = i
            }
        }

        guard let idx = bestOfficialIndex, idx > 0 else { return results }

        var copy = results
        let promoted = copy.remove(at: idx)
        copy.insert(promoted, at: 0)
        return copy
    }

    // MARK: - Intent

    static func detectIntent(_ q: String, tokens: Set<String>) -> QueryIntent {
        let lower = q.lowercased()
        let informationalSignals = ["how", "why", "what", "when", "where", "tutorial", "guide", "best", "review", "compare", "vs"]
        if informationalSignals.contains(where: { lower.contains($0) }) {
            return .informational
        }
        if lower.count <= 20 && tokens.count <= 2 {
            return .navigational
        }
        let brandSignals = [
            "terafab", "xai", "tesla", "spacex", "openai", "anthropic", "github", "apple", "google",
            "roblox", "minecraft", "netflix", "spotify", "discord", "twitch", "steam", "epic",
            "amazon", "microsoft", "adobe", "figma", "notion", "stripe", "vercel", "cloudflare",
            "instagram", "tiktok", "linkedin", "facebook", "twitter", "reddit", "wikipedia"
        ]
        if brandSignals.contains(where: { lower.contains($0) }) {
            return .navigational
        }
        if tokens.count <= 3 && !lower.contains("?") {
            return .navigational
        }
        return .general
    }

    // MARK: - Helpers

    private static func normalizedQuery(_ input: String) -> String {
        input.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(from s: String) -> Set<String> {
        Set(s.split(separator: " ").map(String.init).filter { $0.count > 1 })
    }
}