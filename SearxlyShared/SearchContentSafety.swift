//
//  SearchContentSafety.swift
//  Searxly
//
//  Google-style SafeSearch for native SERP results.
//
//  Three layers (defense in depth):
//  1. SearXNG upstream safesearch=2 (engine-side filtering)
//  2. Bundled open-source adult domain blocklist (~96k domains, HaGeZi / dns-blocklists)
//  3. Local keyword / URL-path heuristics for revealing content on mainstream hosts
//     (the common leak case: innocent query → bikini thumb on flickr/imgur/reddit)
//

import Foundation

extension Notification.Name {
    static let searchContentSafetyDidChange = Notification.Name("Searxly.SearchContentSafetyDidChange")
}

/// Filters sensitive search results locally and forwards strict safesearch to SearXNG when enabled.
@MainActor
@Observable
final class SearchContentSafety {
    static let shared = SearchContentSafety()

    static let settingsKey = "Searxly.SearchContentSafetyEnabled"

    /// On by default — matches Google SafeSearch being enabled out of the box.
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.settingsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.settingsKey)
        }
        set {
            let old = isEnabled
            guard newValue != old else { return }
            UserDefaults.standard.set(newValue, forKey: Self.settingsKey)
            NotificationCenter.default.post(name: .searchContentSafetyDidChange, object: nil)
        }
    }

    /// SearXNG safesearch: 0 = off, 1 = moderate, 2 = strict.
    var searxngSafeSearchLevel: Int? {
        isEnabled ? 2 : nil
    }

    /// Human-readable summary for Settings.
    var blocklistSummary: String {
        let count = SearchContentSafetyBlocklist.loadedDomainCount
        return "Bundled HaGeZi NSFW list (\(count.formatted()) domains) + local keyword filter"
    }

    func searchOptions(pageNo: Int, timeRange: String? = nil) -> SearXNGSearchOptions {
        let range = (timeRange?.isEmpty == false) ? timeRange : nil
        return SearXNGSearchOptions(pageNo: pageNo, safeSearch: searxngSafeSearchLevel, timeRange: range)
    }

    /// Pre-warm the blocklist off the main thread so the first SERP filter is instant.
    func warmBlocklist() {
        Task.detached(priority: .utility) {
            _ = SearchContentSafetyBlocklist.loadedDomainCount
        }
    }

    // MARK: - Local post-filter

    func filterResults(_ results: [SearXNGResult], query: String, category: String?) -> [SearXNGResult] {
        guard isEnabled else { return results }
        return results.filter { !isSensitive($0, query: query, category: category) }
    }

    func isSensitive(_ result: SearXNGResult, query: String, category: String?) -> Bool {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let host = result.displayHost.lowercased()
        let fields = combinedSearchableText(for: result)

        // Layer 2: open-source domain blocklist (result page + thumbnail hosts).
        if isBlockedByDomainList(host: host, mediaURLs: mediaURLText(for: result)) {
            return true
        }

        // Layer 3a: known NSFW URL path patterns (reddit, tumblr, etc.).
        for pattern in Self.blockedURLPathFragments where fields.contains(pattern) {
            return true
        }

        // Layer 3b: keyword heuristics when the query does not justify the term.
        for token in Self.sensitiveTokens {
            if Self.containsWholeWord(token, in: fields),
               !Self.containsWholeWord(token, in: normalizedQuery) {
                return true
            }
        }

        // Extra scrutiny for media tabs where thumbnails are the primary surface.
        if category == "images" || category == "videos" {
            let mediaURLs = mediaURLText(for: result)
            if !mediaURLs.isEmpty {
                if let mediaHost = URL(string: result.img_src ?? result.thumbnail ?? result.thumbnail_src ?? "")?.host,
                   isBlockedByDomainList(host: mediaHost, mediaURLs: "") {
                    return true
                }
                for pattern in Self.blockedURLPathFragments where mediaURLs.contains(pattern) {
                    return true
                }
                for token in Self.mediaSensitiveTokens {
                    if Self.containsWholeWord(token, in: mediaURLs),
                       !Self.containsWholeWord(token, in: normalizedQuery) {
                        return true
                    }
                }
            }
        }

        return false
    }

    // MARK: - Internals

    private static let blockedURLPathFragments: [String] = [
        "/r/nsfw", "/r/gonewild", "/r/realgirls", "/r/bikinis", "/r/ass/",
        "mature_content", "mature-content", "/adult/", "/nsfw/", "/xxx/",
        "tag=bikini", "tags=bikini", "bikini-", "-bikini", "lingerie",
        "underwear", "topless", "nude-", "-nude", "nudity", "sexy-", "-sexy"
    ]

    private static let sensitiveTokens: Set<String> = [
        "porn", "pornhub", "xxx", "nsfw", "nude", "naked", "nudity", "topless",
        "bikini", "lingerie", "thong", "panties", "underwear", "cleavage",
        "erotic", "hentai", "onlyfans", "camgirl", "stripper", "playboy",
        "sexy", "seductive", "provocative", "twerk", "booty", "buttocks",
        "boobs", "breasts", "nipple", "fetish", "bdsm", "orgasm",
        "escort", "prostitute", "prostitution", "milf", "gilf",
        "hardcore", "softcore", "cumshot", "blowjob", "handjob"
    ]

    private static let mediaSensitiveTokens: Set<String> = [
        "bikini", "lingerie", "thong", "topless", "nude", "nsfw", "sexy",
        "underwear", "panties", "cleavage", "booty", "butt", "ass"
    ]

    private func mediaURLText(for result: SearXNGResult) -> String {
        [result.img_src, result.thumbnail, result.thumbnail_src]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    private func isBlockedByDomainList(host: String, mediaURLs: String) -> Bool {
        if SearchContentSafetyBlocklist.isBlockedHost(host) { return true }
        // Thumbnail may be served from a CDN on a blocked domain even when the page host is benign.
        if !mediaURLs.isEmpty {
            let candidates = mediaURLs.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for raw in candidates {
                if let thumbHost = URL(string: raw)?.host,
                   SearchContentSafetyBlocklist.isBlockedHost(thumbHost) {
                    return true
                }
            }
        }
        return false
    }

    private func combinedSearchableText(for result: SearXNGResult) -> String {
        [
            result.title,
            result.url,
            result.content ?? "",
            result.img_src ?? "",
            result.thumbnail ?? "",
            result.thumbnail_src ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty, !text.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "\\b\(escaped)\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private init() {
        let resourceURL = Bundle.main.url(
            forResource: SearchContentSafetyBlocklist.resourceName,
            withExtension: "txt"
        ) ?? Bundle.main.url(
            forResource: SearchContentSafetyBlocklist.resourceName,
            withExtension: "txt",
            subdirectory: "ContentSafety"
        )
        SearchContentSafetyBlocklist.setCachedResourceURL(resourceURL)
        warmBlocklist()
    }
}