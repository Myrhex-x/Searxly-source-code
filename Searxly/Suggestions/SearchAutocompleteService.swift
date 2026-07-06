//
//  SearchAutocompleteService.swift
//  Searxly
//
//  Remote search-query autocomplete for the address bar.
//  Uses the same open backends as SearXNG (DuckDuckGo by default):
//  - Prefer the user's private SearXNG instance `/autocompleter` endpoint when configured.
//  - Fall back to DuckDuckGo's public autocomplete API (same format SearXNG uses internally).
//  Only search *queries* are fetched remotely — site/URL suggestions stay 100% local.
//

import Foundation

enum SearchAutocompleteService {

    private static let minQueryLength = 2
    private static let maxRemoteResults = 3

    /// Fetches remote search-query completions for the typed prefix.
    /// Returns an empty array for URL-like input or when the query is too short.
    /// Only contacts the user's own private SearXNG instances — no third-party fallback.
    static func fetchSearchCompletions(
        query: String,
        instances: [SearXNGInstance],
        localeCode: String
    ) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minQueryLength else { return [] }
        guard !looksLikeURLInput(trimmed) else { return [] }

        // Route through the user's SearXNG instances only.
        // No third-party fallback: sending partial queries to external servers would be
        // a privacy leak incompatible with Searxly's local-only design.
        for instance in instances {
            let base = instance.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let results = await fetchFromSearXNG(baseURL: base, query: trimmed, localeCode: localeCode),
               !results.isEmpty {
                return sanitize(results, original: trimmed)
            }
        }

        return []
    }

    // MARK: - SearXNG instance

    private static func fetchFromSearXNG(baseURL: String, query: String, localeCode: String) async -> [String]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/autocompleter?q=\(encoded)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        request.setValue("Searxly/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        // The autocompleter has no `language` param; with `search.default_lang: auto` the
        // instance derives the language from Accept-Language, so completions follow the
        // same choice as search results.
        if !localeCode.isEmpty {
            request.setValue("\(localeCode), en;q=0.5", forHTTPHeaderField: "Accept-Language")
        }
        // Intentionally omit X-Requested-With so SearXNG returns browser-style JSON:
        // ["query", ["suggestion1", "suggestion2", ...]]

        if baseURL.contains("localhost") || baseURL.contains("127.0.0.1") || baseURL.contains("::1") {
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Real-IP")
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Forwarded-For")
        }

        do {
            try PrivacyGate.assertSearchEgressAllowed(to: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return parseSearXNGResponse(data)
        } catch {
            return nil
        }
    }

    private static func parseSearXNGResponse(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Browser URL-bar format: ["prefix", ["sug1", "sug2", ...]]
        if let arr = json as? [Any], arr.count >= 2, let suggestions = arr[1] as? [String] {
            return suggestions
        }

        // SearXNG form AJAX format: ["sug1", "sug2", ...]
        if let suggestions = json as? [String] {
            return suggestions
        }

        return nil
    }

    // MARK: - Helpers

    /// True when the user is likely typing a website address, not a search query.
    static func looksLikeURLInput(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.contains("://") { return true }
        // Multi-word input is almost certainly a search query, not a URL.
        if t.contains(" ") { return false }
        if t.hasPrefix("localhost") || t.hasPrefix("127.0.0.1") || t.hasPrefix("::1") { return true }
        // Single-word with a dot: only treat as URL when the part after the last dot looks like
        // a known TLD or is a bare IP component, not an abbreviation or decimal number alone.
        if let dotRange = t.range(of: ".", options: .backwards) {
            let tld = String(t[dotRange.upperBound...])
            // Must have at least one char before AND after the dot, and the suffix must be
            // alphabetic (real TLD) not numeric (version number like "v1.2") or empty (trailing dot mid-typing).
            let prefix = String(t[..<dotRange.lowerBound])
            if !prefix.isEmpty, !tld.isEmpty, tld.allSatisfy({ $0.isLetter }) {
                return true
            }
        }
        return false
    }

    private static func sanitize(_ results: [String], original: String) -> [String] {
        var seen = Set<String>()
        let originalLower = original.lowercased()
        var out: [String] = []

        for raw in results {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            // Strip SearXNG bang syntax for display (e.g. "!gh swift" → keep as-is for power users,
            // but don't surface exact duplicate of what user already typed).
            let key = cleaned.lowercased()
            guard key != originalLower, seen.insert(key).inserted else { continue }
            out.append(cleaned)
            if out.count >= maxRemoteResults { break }
        }
        return out
    }
}