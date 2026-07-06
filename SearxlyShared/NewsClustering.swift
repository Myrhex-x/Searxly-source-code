//
//  NewsClustering.swift
//  SearxlyShared
//
//  Groups near-duplicate news stories (the same event covered by many outlets) into one cluster with
//  a lead story + additional sources — the data behind the "Full coverage · N sources" affordance.
//
//  Pure + heuristic: normalizes headlines to significant-word sets (dropping stopwords AND the query
//  terms, which appear in ~every result and would otherwise make everything look similar), then greedily
//  merges by Jaccard / containment similarity. Validated against live SearXNG data (96 "elon musk"
//  results → correct clusters, no false merges). Under-merging is preferred over merging distinct stories.
//

import Foundation

struct NewsCluster: Identifiable {
    /// Highest-ranked (or freshest) story — the one rendered as the row/card.
    let lead: SearXNGResult
    /// Additional distinct-outlet sources covering the same story (excludes the lead).
    let others: [SearXNGResult]

    var id: String { lead.url }
    var sourceCount: Int { 1 + others.count }
    var hasFullCoverage: Bool { !others.isEmpty }
    /// Lead first, then the other sources — the full list for a "Full coverage" expansion.
    var allSources: [SearXNGResult] { [lead] + others }
}

enum NewsClustering {
    /// Similarity at/above which two headlines are treated as the same story.
    static let mergeThreshold = 0.5

    /// Clusters `results` (kept in their incoming order, so the lead is the first/highest-ranked member
    /// of each group). Same-outlet duplicates of an already-clustered story are dropped, not re-listed.
    static func cluster(_ results: [SearXNGResult], query: String) -> [NewsCluster] {
        let strip = queryStripSet(query)
        var acc: [(tokens: Set<String>, lead: SearXNGResult, others: [SearXNGResult], hosts: Set<String>)] = []

        for r in results {
            let tokens = titleTokens(r.title, stripping: strip)
            var bestIndex = -1
            var bestScore = 0.0
            if !tokens.isEmpty {
                for (i, c) in acc.enumerated() {
                    let s = similarity(tokens, c.tokens)
                    if s > bestScore { bestScore = s; bestIndex = i }
                }
            }

            if bestIndex >= 0, bestScore >= mergeThreshold {
                let host = hostKey(r.url)
                // Only a NEW outlet counts as an extra source; a same-site re-run is a dupe → dropped.
                if !acc[bestIndex].hosts.contains(host) {
                    acc[bestIndex].others.append(r)
                    acc[bestIndex].hosts.insert(host)
                }
            } else {
                acc.append((tokens, r, [], [hostKey(r.url)]))
            }
        }

        return acc.map { NewsCluster(lead: $0.lead, others: $0.others) }
    }

    // MARK: - Internals

    /// Jaccard overlap, or containment when one headline's significant words are a strong subset of the
    /// other (requires ≥3 shared words so short/generic titles don't over-merge).
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        guard inter > 0 else { return 0 }
        let jaccard = Double(inter) / Double(a.union(b).count)
        let containment = inter >= 3 ? Double(inter) / Double(min(a.count, b.count)) : 0
        return max(jaccard, containment)
    }

    private static func titleTokens(_ title: String, stripping strip: Set<String>) -> Set<String> {
        let cleaned = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return Set(
            cleaned.split(separator: " ").map(String.init)
                .filter { $0.count >= 3 && !stopwords.contains($0) && !strip.contains($0) }
        )
    }

    /// Query words to strip from headline tokens (present in ~all results → no discriminative value).
    /// No length filter — even short query words ("ai", "x") should be stripped.
    private static func queryStripSet(_ query: String) -> Set<String> {
        let cleaned = query.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return Set(cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    private static func hostKey(_ url: String) -> String {
        (URL(string: url)?.host ?? url).replacingOccurrences(of: "www.", with: "").lowercased()
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "says", "say", "what", "how", "why",
        "are", "was", "were", "has", "have", "had", "its", "his", "her", "she", "him", "not", "but",
        "you", "your", "out", "who", "new", "now", "get", "got", "will", "would", "could", "should",
        "about", "after", "over", "into", "than", "then", "them", "they", "their", "been", "being",
        "just", "more", "most", "some", "such", "only", "also", "did", "does", "done", "off", "per",
        "via", "amp", "here", "when", "where", "which", "while", "amid", "says"
    ]
}
