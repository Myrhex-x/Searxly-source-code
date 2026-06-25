//
//  WikipediaTitleResolver.swift
//  Searxly
//
//  Resolves a free-text subject to canonical encyclopedia titles via Wikipedia's opensearch API.
//  Grokipedia uses Wikipedia-style titles (spaces → underscores), so these titles make excellent
//  Grokipedia slug candidates — this is what lets the knowledge panel cover the long tail of entities
//  (e.g. "torproject" → "The Tor Project" → grokipedia.com/page/The_Tor_Project) without a giant
//  hand-curated slug catalog. Only used as a fallback when curated/inferred slugs miss.
//

import Foundation

enum WikipediaTitleResolver {

    /// Returns up to `limit` canonical article titles for the subject (most relevant first), or [].
    static func canonicalTitles(for subject: String, limit: Int = 3) async -> [String] {
        let q = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&namespace=0&format=json&limit=\(limit)&search=\(encoded)")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Searxly/1.0 (Knowledge Panel; macOS)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              // opensearch shape: [ query, [titles], [descriptions], [urls] ]
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let titles = json[1] as? [String]
        else { return [] }

        return titles
    }
}
