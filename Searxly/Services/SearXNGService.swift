//
//  SearXNGService.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Privacy-respecting search via SearXNG (supports multiple instances - Phase 8)
//

import Foundation
import os

// SearXNGSearchOptions moved to SearxlyShared/SearXNGModels.swift (shared with iOS).

/// Lightweight service for talking to any SearXNG instance.
/// The UI (ContentView) decides which instance URL to use.
@MainActor
final class SearXNGService {
    static let shared = SearXNGService()
    private init() {}

    // Public instances are intentionally not supported or listed here.
    // Searxly requires users to provide their own private SearXNG instances only.
    // This preserves privacy and avoids unreliable third-party infrastructure.

    /// Performs a search against the given SearXNG instance.
    /// This is only used for queries typed in the address bar (not for normal web browsing).
    ///
    /// - Parameter language: Optional language code (e.g. "en", "fr") that is forwarded to SearXNG
    ///   via the `language` query parameter. This is the primary mechanism that makes search results
    ///   respect the user's chosen app language.
    func search(
        query: String,
        categories: String? = nil,
        instanceURL: String,
        language: String? = nil,
        options: SearXNGSearchOptions = .standard
    ) async throws -> [SearXNGResult] {
        let response = try await searchPage(
            query: query,
            categories: categories,
            instanceURL: instanceURL,
            language: language,
            options: options
        )
        return response.results ?? []
    }

    /// Full JSON page response (used for pagination / load-more).
    func searchPage(
        query: String,
        categories: String? = nil,
        instanceURL: String,
        language: String? = nil,
        options: SearXNGSearchOptions = .standard
    ) async throws -> SearXNGResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearXNGResponse(query: query, results: [], suggestions: nil) }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw URLError(.badURL)
        }

        let base = Self.ipv4PreferredLocalURL(
            instanceURL.hasSuffix("/") ? String(instanceURL.dropLast()) : instanceURL
        )
        var urlString = "\(base)/search?q=\(encoded)&format=json&pageno=\(max(1, options.pageNo))"
        if let categories, !categories.isEmpty {
            if let encodedCat = categories.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&categories=\(encodedCat)"
            }
        }
        if let language, !language.isEmpty {
            if let encodedLang = language.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&language=\(encodedLang)"
            }
        }
        if let safe = options.safeSearch {
            urlString += "&safesearch=\(safe)"
        }
        if let range = options.timeRange, !range.isEmpty {
            if let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&time_range=\(encodedRange)"
            }
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Searxly/1.0 (macOS; +https://github.com/Myrhex-x/Searxly)", forHTTPHeaderField: "User-Agent")

        // Accept-Language: must lead with the user's chosen search language.
        // default_lang: "auto" in SearXNG uses Accept-Language as the primary signal
        // (the ?language= param in the URL is a secondary override that some engine
        // adapters ignore). Putting the chosen language first in this header ensures
        // Bing, DDG, and Brave inside SearXNG all receive the correct language hint.
        let primaryLang = language?.isEmpty == false ? language! : (Locale.preferredLanguages.first ?? "en-US")
        let primaryBase = primaryLang.split(separator: "-").first.map(String.init)?.lowercased() ?? primaryLang.lowercased()
        let fallbacks = Locale.preferredLanguages
            .filter { !$0.lowercased().hasPrefix(primaryBase) }
            .prefix(2)
        let acceptLangParts = ([primaryLang] + fallbacks).prefix(3)
        let acceptLang = acceptLangParts
            .enumerated()
            .map { i, lang in i == 0 ? lang : "\(lang);q=\(String(format: "%.1f", 1.0 - Double(i) * 0.2))" }
            .joined(separator: ", ")
        request.setValue(acceptLang, forHTTPHeaderField: "Accept-Language")

        // Help local/private instances that have bot detection enabled.
        // Many self-hosted SearXNG instances (especially with default limiter) require these headers.
        if instanceURL.contains("localhost") || instanceURL.contains("127.0.0.1") || instanceURL.contains("::1") {
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Real-IP")
            request.setValue("127.0.0.1", forHTTPHeaderField: "X-Forwarded-For")
        }

        try PrivacyGate.assertSearchEgressAllowed(to: url)   // fail-closed: no search egress while Maximum Privacy is unprotected (loopback allowed once SearXNG's upstream is Tor-routed)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 429 {
            throw SearXNGError.rateLimited
        }

        if !(200...299).contains(httpResponse.statusCode) {
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
               contentType.contains("text/html") {
                throw SearXNGError.instanceReturnedHTML
            }
            throw URLError(.badServerResponse)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") {
            throw SearXNGError.instanceReturnedHTML
        }

        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(SearXNGResponse.self, from: data)
            return decoded
        } catch {
            throw SearXNGError.invalidResponse
        }
    }

    /// Tries to perform a search using the user's configured SearXNG instances (all private/local).
    /// No public fallback instances are used — public instances have been removed
    /// because they are unreliable and compromise the privacy model.
    ///
    /// - Parameter language: Optional language code forwarded to the underlying search call
    ///   so that SearXNG can prefer results in the user's chosen language.
    func searchWithFallback(
        query: String,
        categories: String? = nil,
        instances: [SearXNGInstance],
        language: String? = nil,
        options: SearXNGSearchOptions = .standard
    ) async throws -> (results: [SearXNGResult], usedInstanceURL: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }

        guard !instances.isEmpty else {
            throw SearXNGError.noWorkingInstance
        }

        var lastError: Error?

        for instance in instances {
            do {
                let results = try await search(
                    query: trimmed,
                    categories: categories,
                    instanceURL: instance.url,
                    language: language,
                    options: options
                )
                if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseSearXNGLogging {
                    Log.search.info("[Dev][SearXNG] Search succeeded via \(instance.displayName)")
                }
                // Normal success is silent for privacy (no need to log every search)
                return (results, instance.url)
            } catch {
                lastError = error
                if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseSearXNGLogging {
                    Log.search.error("[Dev][SearXNG] Instance \(instance.displayName) failed: \(error.localizedDescription). Trying next...")
                }
            }
        }

        if let error = lastError {
            throw error
        } else {
            throw SearXNGError.noWorkingInstance
        }
    }

    /// Avoid `localhost` → `::1` when SearXNG binds IPv4-only on 127.0.0.1.
    private static func ipv4PreferredLocalURL(_ url: String) -> String {
        guard url.contains("://localhost") else { return url }
        return url.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
    }
}

/// Custom errors for better user messaging from SearXNG searches (address bar only)
enum SearXNGError: LocalizedError {
    case rateLimited
    case instanceReturnedHTML
    case invalidResponse
    case noWorkingInstance

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "All SearXNG instances are rate-limiting requests right now. Please try again later."
        case .instanceReturnedHTML:
            return "No working SearXNG instance could be reached. Configure or add a private/local instance in Settings."
        case .invalidResponse:
            return "All SearXNG instances returned invalid data. Check your private instance configuration in Settings."
        case .noWorkingInstance:
            return "No configured SearXNG instance could complete the search. Add your private/local instance in Settings."
        }
    }
}
