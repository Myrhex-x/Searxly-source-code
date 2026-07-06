//
//  SearchResultProcessor.swift
//  Searxly
//
//  Central post-fetch pipeline for native SERP results (2026-06 rework).
//  Category-aware dedup, media filtering, Grokipedia boost, and ranker gating.
//

import Foundation

enum SearchResultProcessor {

    /// Processes raw SearXNG results for display. When `append` is true, merges with `existing`.
    static func process(
        raw: [SearXNGResult],
        existing: [SearXNGResult] = [],
        query: String,
        category: String?,
        append: Bool
    ) -> [SearXNGResult] {
        let base = append ? existing : []
        let merged = base + raw

        let normalized = merged.map { normalizeResultURLs($0) }

        let isMedia = category == "images" || category == "videos"
        let isNews = category == "news"

        var processed: [SearXNGResult]
        if isMedia {
            processed = deduplicateMedia(normalized)
            processed = processed.filter { SearchMediaURLResolver.hasAnyThumbnailField($0) }
        } else {
            processed = deduplicateByCanonicalURL(normalized)
        }

        processed = SearchContentSafety.shared.filterResults(processed, query: query, category: category)

        if isMedia {
            return processed
        }

        processed = SearchResultRanker.reranked(processed, query: query, category: category)
        if !isNews {
            processed = applyDomainDiversity(processed, maxPerHost: 2, topN: 15)
        }

        // Grokipedia-first SERP: single combined pass (promote Grokipedia, suppress Wikipedia).
        processed = SERPSourcePolicy.applyAll(processed, query: query)

        return processed
    }

    /// Returns count of genuinely new items when appending (for pagination end detection).
    /// `query` must match the active search query so content-safety filtering uses the same
    /// threshold as the main pipeline — passing "" causes over-filtering and premature pagination stop.
    static func countNewItems(existing: [SearXNGResult], incoming: [SearXNGResult], category: String?, query: String = "") -> Int {
        let isMedia = category == "images" || category == "videos"
        let existingKeys: Set<String>
        if isMedia {
            existingKeys = Set(existing.compactMap { mediaDedupKey($0) })
        } else {
            existingKeys = Set(existing.map { canonicalURLKey($0.url) })
        }

        let processed = process(raw: incoming, query: query, category: category, append: false)
        if isMedia {
            return processed.filter { mediaDedupKey($0).map { !existingKeys.contains($0) } ?? false }.count
        }
        return processed.filter { !existingKeys.contains(canonicalURLKey($0.url)) }.count
    }

    // MARK: - Dedup

    static func deduplicateByCanonicalURL(_ results: [SearXNGResult]) -> [SearXNGResult] {
        var seen = Set<String>()
        return results.filter { seen.insert(canonicalURLKey($0.url)).inserted }
    }

    static func deduplicateMedia(_ results: [SearXNGResult]) -> [SearXNGResult] {
        var seenURL = Set<String>()
        var seenThumb = Set<String>()
        return results.filter { r in
            let urlKey = canonicalURLKey(r.url)
            guard seenURL.insert(urlKey).inserted else { return false }
            if let thumbKey = mediaDedupKey(r) {
                return seenThumb.insert(thumbKey).inserted
            }
            return true
        }
    }

    static func canonicalURLKey(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url.lowercased() }
        components.host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        let tracking = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fbclid", "gclid", "mc_cid", "mc_eid"]
        if var items = components.queryItems {
            items.removeAll { tracking.contains($0.name.lowercased()) }
            components.queryItems = items.isEmpty ? nil : items
        }
        var path = components.path
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
            components.path = path
        }
        return (components.string ?? url).lowercased()
    }

    private static func mediaDedupKey(_ result: SearXNGResult) -> String? {
        let fields = [result.img_src, result.thumbnail, result.thumbnail_src]
        for f in fields {
            let t = f?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return t.lowercased() }
        }
        return nil
    }

    private static func normalizeResultURLs(_ result: SearXNGResult) -> SearXNGResult {
        // SearXNGResult is a struct with let properties — we can't mutate.
        // Canonical dedup uses normalized keys; original URLs preserved for navigation.
        result
    }

    // MARK: - Domain diversity

    static func applyDomainDiversity(_ results: [SearXNGResult], maxPerHost: Int, topN: Int) -> [SearXNGResult] {
        guard results.count > 1 else { return results }

        var hostCounts: [String: Int] = [:]
        var kept: [SearXNGResult] = []
        var deferred: [SearXNGResult] = []

        for (index, result) in results.enumerated() {
            let host = (URL(string: result.url)?.host ?? result.url)
                .lowercased()
                .replacingOccurrences(of: "www.", with: "")
            let count = hostCounts[host, default: 0]

            if index < topN && count >= maxPerHost {
                deferred.append(result)
            } else {
                kept.append(result)
                hostCounts[host] = count + 1
            }
        }

        return kept + deferred
    }
}