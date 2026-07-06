//
//  SearxngClient.swift
//  SearxlyShared
//
//  A lean, self-contained SearXNG JSON search client. Unlike the macOS SearXNGService (which is wired
//  into BrowserState / DeveloperSettings / PrivacyGate), this has no app coupling — it just fetches
//  `/search?q=…&format=json` against a configured instance and decodes shared SearXNGResult models.
//  Used by the iOS app to render a native SERP; macOS keeps its richer service for now.
//

import Foundation

/// Results plus SearXNG's related-search suggestions from one JSON response.
struct SearxngSearchResult {
    let results: [SearXNGResult]
    let suggestions: [String]
}

struct SearxngClient {

    /// Back-compat: results only.
    func search(
        _ query: String,
        base: String,
        categories: String = "general",
        safeSearch: Int = 1,
        language: String = "auto",
        pageNo: Int = 1,
        timeout: TimeInterval = 12
    ) async throws -> [SearXNGResult] {
        try await searchDetailed(query, base: base, categories: categories, safeSearch: safeSearch,
                                 language: language, pageNo: pageNo, timeout: timeout).results
    }

    /// Results + related-search suggestions.
    func searchDetailed(
        _ query: String,
        base: String,
        categories: String = "general",
        safeSearch: Int = 1,
        language: String = "auto",
        pageNo: Int = 1,
        timeout: TimeInterval = 12
    ) async throws -> SearxngSearchResult {
        var comps = URLComponents(string: "\(base)/search")
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "categories", value: categories),
            URLQueryItem(name: "safesearch", value: String(safeSearch)),
            URLQueryItem(name: "pageno", value: String(pageNo)),
        ]
        if language != "auto" { items.append(URLQueryItem(name: "language", value: language)) }
        comps?.queryItems = items
        guard let url = comps?.url else { throw SearxngClientError.badURL }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // A browser-ish UA makes some instances serve JSON instead of a challenge/landing page.
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else { throw SearxngClientError.invalidResponse }
        guard http.statusCode == 200 else { throw SearxngClientError.httpStatus(http.statusCode) }

        // Some instances return an HTML page when the JSON format isn't enabled or when rate-limited.
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksJSON = contentType.contains("json") || data.first == UInt8(ascii: "{")
        guard looksJSON else { throw SearxngClientError.notJSON }

        let decoded = try JSONDecoder().decode(SearXNGResponse.self, from: data)
        let suggestions = (decoded.suggestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return SearxngSearchResult(
            results: SearXNGResult.deduplicated(decoded.results ?? []),
            suggestions: suggestions
        )
    }
}

enum SearxngClientError: LocalizedError {
    case badURL
    case invalidResponse
    case httpStatus(Int)
    case notJSON

    var errorDescription: String? {
        switch self {
        case .badURL:          return "Couldn't build the search URL."
        case .invalidResponse: return "No response from the search instance."
        case .httpStatus(let code): return "The search instance returned an error (\(code))."
        case .notJSON:         return "This instance didn't return JSON. Enable the JSON format on it, or pick another instance in Settings."
        }
    }
}
