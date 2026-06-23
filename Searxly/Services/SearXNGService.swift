//
//  SearXNGService.swift
//  Searxly
//
//  Created on 24/05/2026. (Searxly source distribution)
//  Privacy-respecting search via SearXNG (supports multiple instances - Phase 8)
//

import Foundation
import os

/// Options forwarded to the SearXNG JSON search API.
struct SearXNGSearchOptions: Sendable {
    /// Explicit nonisolated default — required for default parameter values on @MainActor methods (Swift 6).
    nonisolated static let standard = SearXNGSearchOptions(pageNo: 1, safeSearch: nil, timeRange: nil)

    var pageNo: Int
    var safeSearch: Int?
    var timeRange: String?

    init(pageNo: Int = 1, safeSearch: Int? = nil, timeRange: String? = nil) {
        self.pageNo = pageNo
        self.safeSearch = safeSearch
        self.timeRange = timeRange
    }
}

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
        guard !trimmed.isEmpty else { return SearXNGResponse(query: query, results: []) }

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

// MARK: - Response Models (kept here for service locality, also referenced from Models.swift via same module)

struct SearXNGResult: Decodable, Identifiable {
    var id: String { url }

    let title: String
    let url: String
    let content: String?
    let engine: String?

    // Additional fields for richer search result display (flat SERP redesign)
    let publishedDate: String?   // Present on some news/articles; surfaced as extra detail in result meta row
    let engines: [String]?       // Some responses include multiple contributing engines; single `engine` kept for primary display

    // Image / video specific fields returned by SearXNG when using categories=images or videos
    let img_src: String?        // Direct image URL (best for thumbnails / preview)
    let thumbnail: String?      // Sometimes a smaller dedicated thumb
    let thumbnail_src: String?  // Alternative thumb field some engines use
    let img_format: String?
    let resolution: String?
    let filesize: String?

    // Optional dimensions (emitted by some engines / SearXNG result types). Used for natural-aspect
    // Google-like image grid tiles instead of forcing square crops. Fall back to resolution string parse.
    let width: Int?
    let height: Int?
    let thumb_width: Int?
    let thumb_height: Int?

    enum CodingKeys: String, CodingKey {
        case title, url, content, engine, publishedDate, engines
        case img_src, thumbnail, thumbnail_src, img_format, resolution, filesize
        case width, height, thumb_width, thumb_height
    }
}

// MARK: - Display helpers & utilities (used by SearchResultCard and media grid for consistent, readable SERP)
// These are deliberately kept with the model for service locality (no new files, minimal surface).
// All are pure, zero-side-effect, and defensive (never crash on bad data from upstream engines).

extension SearXNGResult {
    /// www-stripped host for meta rows and deduping. Matches the spirit of the minimal web theme (netloc only).
    var displayHost: String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// Short, scannable path segment for the meta row when useful. Avoids dumping giant paths.
    /// Prefers host+short-path or host+…+tail. Falls back gracefully.
    var displayPath: String {
        guard let u = URL(string: url), u.host != nil else { return "" }
        let p = u.path
        if p.isEmpty || p == "/" { return "" }
        if p.count <= 32 {
            return p
        }
        // Middle ellipsis for long paths (more readable than crude prefix/suffix in flat row)
        let head = p.prefix(20)
        let tail = p.suffix(8)
        return String(head) + "…" + String(tail)
    }

    /// Primary engine for display (prefers the singular `engine` field, falls back to first of `engines`).
    var primaryEngine: String? {
        if let e = engine, !e.isEmpty { return e }
        return engines?.first
    }

    /// Compact engine attribution string for the meta row, e.g. "google", "google +2", or nil.
    /// Uses the multi-engine array when present (common with SearXNG aggregation).
    var enginesDisplay: String? {
        let list = (engines?.isEmpty == false ? engines : (engine.map { [$0] })) ?? []
        let cleaned = list.compactMap { $0.isEmpty ? nil : $0 }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count == 1 {
            return cleaned[0]
        }
        return "\(cleaned[0]) +\(cleaned.count - 1)"
    }

    /// Best-effort human presentation of publishedDate for news/articles.
    /// Tries common formats; always falls back to the raw (trimmed) string so we never lose info or crash.
    func formattedPublishedDate() -> String? {
        guard let raw = publishedDate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Fast path: already looks like a nice short human string from the engine
        if raw.count <= 24 && !raw.contains("T") && !raw.contains(":") {
            return raw
        }

        // Try ISO8601 / RFC3339 style
        if let date = Self.isoDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }

        // Fallback: common yyyy-MM-dd or yyyy/MM/dd
        if let date = Self.ymdDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }
        if let date = Self.ymdSlashDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }

        // Last resort: return the cleaned raw so the UI still shows *something* useful
        return raw
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static let ymdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let ymdSlashDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    // MARK: Media aspect (for Google-like natural proportion grids, not forced squares)
    /// Returns the best-known aspect ratio (width/height) for this result's thumbnail.
    /// Prefers explicit numeric width/height (or thumb_* variants), then parses the `resolution`
    /// string (supports "1920x1080", "1920 x 1080", "1920×1080"). Falls back to nil.
    /// Callers (MediaGridItem) use a category-appropriate default when this is nil.
    var thumbnailAspectRatio: CGFloat? {
        // Explicit dimensions first (some engines / result types surface these)
        if let w = width ?? thumb_width, let h = height ?? thumb_height, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        guard let raw = resolution?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Normalize separators
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
                           .replacingOccurrences(of: "×", with: "x")
                           .replacingOccurrences(of: "X", with: "x")
                           .lowercased()
        let parts = cleaned.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              h > 0 else { return nil }
        return CGFloat(w / h)
    }
}

/// Client-side deduplication by canonical URL (preserves first-seen order).
/// Replicates the exact pattern used in SearchMediaGrid so text results and media stay consistent.
/// Called from the view layer (or optionally BrowserState) before rendering the flat list.
extension SearXNGResult {
    static func deduplicated(_ results: [SearXNGResult]) -> [SearXNGResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.url).inserted }
    }
}

struct SearXNGResponse: Decodable {
    let query: String?
    let results: [SearXNGResult]?
}