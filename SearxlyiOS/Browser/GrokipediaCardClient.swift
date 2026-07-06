//
//  GrokipediaCardClient.swift
//  SearxlyiOS
//
//  Fetches the opening paragraph of a Grokipedia article for the SERP knowledge card — a trimmed
//  iOS port of the macOS GrokipediaArticleClient (same layout-variance handling: tts-block span,
//  bare-text lead, meta-description fallback). Anonymous ephemeral fetch, session-cached, no
//  slug catalog: the slug comes from the Wikipedia-resolved canonical title, which also gives
//  typo rescue for free.
//

import Foundation

struct GrokipediaSnippet {
    let title: String
    let paragraph: String
    let image: URL?
    let pageURL: URL
    let facts: [KnowledgeFact]
}

enum GrokipediaCardClient {

    @MainActor private static var cache: [String: GrokipediaSnippet?] = [:]

    @MainActor
    static func fetch(slug rawSlug: String) async -> GrokipediaSnippet? {
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !slug.isEmpty else { return nil }
        if let hit = cache[slug.lowercased()] { return hit }

        let snippet = await fetchArticle(slug: slug)
        cache[slug.lowercased()] = snippet
        return snippet
    }

    private static func fetchArticle(slug: String) async -> GrokipediaSnippet? {
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://grokipedia.com/page/\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.ephemeral  // no cookies, nothing shared
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              isValidArticlePage(html, expectedSlug: slug),
              let paragraph = extractFirstParagraph(from: html)
        else { return nil }

        return GrokipediaSnippet(
            title: extractTitle(from: html, fallbackSlug: slug),
            paragraph: paragraph,
            image: extractImage(from: html),
            pageURL: url,
            facts: extractInfoboxFacts(from: html)
        )
    }

    // MARK: - Infobox facts (Born, Founded, Headquarters… — same two layouts as macOS)

    private static let skippedLabels: Set<String> = [
        "signature", "website", "portrait", "logo", "image", "caption", "motto",
    ]

    private static func extractInfoboxFacts(from html: String) -> [KnowledgeFact] {
        guard let marker = html.range(of: "<!-- Article body") else { return [] }

        // Older layout: a <dl> infobox (dt/dd pairs) before the article-body marker.
        let infoboxHTML = String(html[..<marker.lowerBound])
        let dtDd = factPairs(in: infoboxHTML,
                             pattern: #"<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>"#, limit: 40)
        if !dtDd.isEmpty { return buildFacts(from: dtDd) }

        // Newer layout: "<span data-tts-block …><strong>Label</strong> value</span>" rows.
        let bodyHTML = String(html[marker.lowerBound...])
        let strong = factPairs(in: bodyHTML,
                               pattern: #"<span[^>]*data-tts-block="true"[^>]*>\s*<strong>(.*?)</strong>(.*?)</span>"#,
                               limit: 40)
        return buildFacts(from: strong)
    }

    private static func factPairs(in html: String, pattern: String, limit: Int) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var pairs: [(String, String)] = []
        for match in regex.matches(in: html, range: range).prefix(limit) {
            guard match.numberOfRanges >= 3,
                  let l = Range(match.range(at: 1), in: html),
                  let v = Range(match.range(at: 2), in: html) else { continue }
            pairs.append((String(html[l]), String(html[v])))
        }
        return pairs
    }

    private static func buildFacts(from raw: [(String, String)]) -> [KnowledgeFact] {
        var facts: [KnowledgeFact] = []
        var seen = Set<String>()
        for (rawLabel, rawValue) in raw {
            let label = stripHTML(rawLabel)
            let value = normalizeFactValue(stripHTML(rawValue))
            guard label.count >= 2, label.count <= 28, !label.contains("."),
                  value.count >= 2, !skippedLabels.contains(label.lowercased()),
                  seen.insert(label.lowercased()).inserted else { continue }
            facts.append(KnowledgeFact(label: label, value: value))
            if facts.count == 6 { break }
        }
        return facts
    }

    private static func normalizeFactValue(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Concatenated-span artifacts ("New York CityU.S.") — re-space lower→Upper boundaries.
        if let regex = try? NSRegularExpression(pattern: #"([a-z])([A-Z])"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 $2")
        }
        if text.count > 160 { text = String(text.prefix(160)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validation (don't render a card from a 404 shell or the search page)

    private static func isValidArticlePage(_ html: String, expectedSlug: String) -> Bool {
        let normalized = expectedSlug.lowercased().replacingOccurrences(of: "_", with: " ")
        if let canonical = firstMatch(#"<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']"#, in: html),
           let last = canonical.split(separator: "/").last {
            let canonicalSlug = last.removingPercentEncoding?.lowercased()
                .replacingOccurrences(of: "_", with: " ") ?? ""
            if canonicalSlug == normalized { return true }
        }
        // Fallback: the page <title> names the article.
        let title = extractTitle(from: html, fallbackSlug: "").lowercased()
        return !title.isEmpty && title == normalized
    }

    // MARK: - Extraction (both known Grokipedia layouts + meta fallback)

    private static func extractFirstParagraph(from html: String) -> String? {
        let articleHTML: String
        if let marker = html.range(of: "<!-- Article body") {
            articleHTML = String(html[marker.lowerBound...])
        } else {
            articleHTML = html
        }

        var candidates: [(position: Int, text: String)] = []

        // Older layout: the lead is the first data-tts-block span that reads like prose.
        if let regex = try? NSRegularExpression(pattern: #"data-tts-block="true"[^>]*>(.*?)</span>"#,
                                                options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(articleHTML.startIndex..., in: articleHTML)
            for match in regex.matches(in: articleHTML, range: range).prefix(24) {
                guard let r = Range(match.range(at: 1), in: articleHTML) else { continue }
                let text = stripHTML(String(articleHTML[r]))
                if isBodyParagraph(text) {
                    candidates.append((match.range.location, text))
                    break
                }
            }
        }

        // Newer layout: a bare text node right after the infobox </div>.
        if let regex = try? NSRegularExpression(pattern: #"</div>\s*([A-Z][^<>]{99,})"#) {
            let range = NSRange(articleHTML.startIndex..., in: articleHTML)
            for match in regex.matches(in: articleHTML, range: range).prefix(8) {
                guard let r = Range(match.range(at: 1), in: articleHTML) else { continue }
                let text = stripHTML(String(articleHTML[r]))
                if isBodyParagraph(text) {
                    candidates.append((match.range.location, text))
                    break
                }
            }
        }

        if let lead = candidates.min(by: { $0.position < $1.position }) { return lead.text }

        // Meta description fallback.
        for pattern in [
            #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']"#,
        ] {
            if let meta = firstMatch(pattern, in: html) {
                let text = stripHTML(meta)
                if text.count >= 48, !text.lowercased().contains("grokipedia") { return text }
            }
        }
        return nil
    }

    /// Infobox rows pass a bare length check — a real lead must be longer AND read as prose.
    private static func isBodyParagraph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 100, trimmed.contains(". ") else { return false }
        let lower = trimmed.lowercased()
        return !lower.contains("<meta") && !lower.contains("googletagmanager") && !lower.contains("(function()")
    }

    private static func extractTitle(from html: String, fallbackSlug: String) -> String {
        if let og = firstMatch(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#, in: html) {
            return cleanTitle(og)
        }
        if let t = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html) {
            return cleanTitle(t)
        }
        return fallbackSlug.replacingOccurrences(of: "_", with: " ")
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = stripHTML(raw)
        for suffix in [" — Grokipedia", " - Grokipedia", " | Grokipedia"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractImage(from html: String) -> URL? {
        guard let raw = firstMatch(#"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#, in: html)
        else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        guard let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }

    // MARK: - Small helpers

    private static func firstMatch(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
