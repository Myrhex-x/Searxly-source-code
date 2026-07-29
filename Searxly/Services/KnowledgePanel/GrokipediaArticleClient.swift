//
//  GrokipediaArticleClient.swift
//  Searxly
//
//  Fetches the opening paragraph of a Grokipedia article directly (no third-party API).
//

import Foundation

struct GrokipediaArticleSnippet: Sendable, Equatable {
    let title: String
    let firstParagraph: String
    let pageURL: String
    /// Best single image (first of `imageURLs`) — kept for call sites that only need one.
    let imageURL: URL?
    /// Ordered Grokipedia image candidates (sharp body images preferred over soft og:image leads).
    let imageURLs: [URL]
    let facts: [KnowledgeFact]

    init(
        title: String,
        firstParagraph: String,
        pageURL: String,
        imageURL: URL?,
        imageURLs: [URL] = [],
        facts: [KnowledgeFact]
    ) {
        self.title = title
        self.firstParagraph = firstParagraph
        self.pageURL = pageURL
        let urls = imageURLs.isEmpty ? (imageURL.map { [$0] } ?? []) : imageURLs
        self.imageURLs = urls
        self.imageURL = imageURL ?? urls.first
        self.facts = facts
    }
}

enum GrokipediaArticleClient {

    private static let cacheTTL: TimeInterval = 2 * 24 * 60 * 60
    private static let maxCacheEntries = 200
    private static var cache: [String: (snippet: GrokipediaArticleSnippet, fetchedAt: Date)] = [:]
    private static let cacheLock = NSLock()

    private static let userAgent = "Searxly/1.0 (Knowledge Panel; macOS)"

    /// Outcome of an article fetch. The distinction matters for caching: a CONFIRMED miss (the slug
    /// genuinely has no article) is safe to negative-cache, while a TRANSIENT failure (network error,
    /// kill switch, or Grokipedia's rate-limit blips — which serve the same "Article Not Found" 404
    /// page a real miss does, verified live 2026-07-05) must never be cached, or one blip hides the
    /// card for the whole negative-TTL window.
    enum FetchOutcome: Sendable {
        case article(GrokipediaArticleSnippet)
        case notFound      // deterministic: persistent 404, wrong canonical, or unparseable content
        case transient     // network/kill-switch/server hiccup — retrying a later search can succeed
    }

    /// Backward-compatible convenience: the snippet, or nil for both kinds of miss.
    static func fetchFirstParagraph(slug: String) async -> GrokipediaArticleSnippet? {
        if case .article(let snippet) = await fetchOutcome(slug: slug) { return snippet }
        return nil
    }

    static func fetchOutcome(slug: String) async -> FetchOutcome {
        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else { return .notFound }

        if let cached = cachedSnippet(for: normalizedSlug) {
            return .article(cached)
        }

        let pageURL = GrokipediaSlugCatalog.pageURL(for: normalizedSlug)
        guard let url = grokipediaRequestURL(for: pageURL) else { return .notFound }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        // Up to two attempts with a short backoff: Grokipedia's cold-cache / rate-limit blips serve a
        // 404 "Article Not Found" page for slugs that load fine seconds later (popular pages worst),
        // so a single 404 proves nothing. Only a 404 that SURVIVES the retry counts as a real miss.
        var notFoundCount = 0
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }

            // Anonymous fetch (article slug only) — rides Tor in Maximum Privacy, fail-closed otherwise.
            guard let lane = await TorLane.current() else { return .transient }
            guard let (data, response) = try? await lane.session.data(for: request) else {
                continue   // network error / timeout → retry once, then report transient below
            }
            guard let http = response as? HTTPURLResponse else { continue }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404 { notFoundCount += 1 }
                continue   // 404 (possibly rate-limit-shaped) or 5xx/429 → retry once
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return .notFound
            }

            // Rate-limit shells often return 200 with an "Article Not Found" title (or empty body).
            // Treat those like HTTP 404: count + retry, don't hard-fail on the first blip (which used
            // to negative-cache the miss and hide the card for 5 minutes).
            guard isValidArticlePage(html, expectedSlug: normalizedSlug) else {
                notFoundCount += 1
                continue
            }
            guard let paragraph = extractFirstParagraph(from: html), paragraph.count >= 48 else {
                notFoundCount += 1
                continue
            }

            let title = extractTitle(from: html, fallbackSlug: normalizedSlug)
            let imageURLs = extractArticleImages(from: html)
            let snippet = GrokipediaArticleSnippet(
                title: title,
                firstParagraph: paragraph,
                pageURL: pageURL,
                imageURL: imageURLs.first,
                imageURLs: imageURLs,
                facts: extractInfoboxFacts(from: html)
            )
            store(snippet, for: normalizedSlug)
            return .article(snippet)
        }
        // Both attempts failed. Only a miss-shaped response on BOTH attempts is a real not-found
        // (twice-confirmed); anything else was network-shaped or a one-off blip → transient.
        return notFoundCount >= 2 ? .notFound : .transient
    }

    // MARK: - Cache

    private static func cachedSnippet(for slug: String) -> GrokipediaArticleSnippet? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = cache[slug] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > cacheTTL {
            cache.removeValue(forKey: slug)
            return nil
        }
        return entry.snippet
    }

    private static func store(_ snippet: GrokipediaArticleSnippet, for slug: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if cache.count >= maxCacheEntries, let oldestKey = cache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            cache.removeValue(forKey: oldestKey)
        }
        cache[slug] = (snippet, Date())
    }

    // MARK: - HTML parsing

    private static func grokipediaRequestURL(for pageURL: String) -> URL? {
        if let direct = URL(string: pageURL) {
            return direct
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "_()-")
        guard let encoded = pageURL.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }

    private static func isValidArticlePage(_ html: String, expectedSlug: String) -> Bool {
        if let title = extractMetaProperty(name: "og:title", from: html),
           title.localizedCaseInsensitiveContains("article not found") {
            return false
        }

        if let canonical = extractLinkRelCanonical(from: html), canonical.contains("/page/") {
            let slugFragment = canonical.split(separator: "/").last.map(String.init) ?? ""
            let decoded = slugFragment
                .replacingOccurrences(of: "%28", with: "(")
                .replacingOccurrences(of: "%29", with: ")")
            if normalizeSlug(decoded) != normalizeSlug(expectedSlug) {
                return false
            }
        }

        return true
    }

    private static func normalizeSlug(_ slug: String) -> String {
        slug.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func extractLinkRelCanonical(from html: String) -> String? {
        let pattern = #"<link[^>]+rel="canonical"[^>]+href="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            let altPattern = #"<link[^>]+href="([^"]*)"[^>]+rel="canonical""#
            guard let altRegex = try? NSRegularExpression(pattern: altPattern, options: .caseInsensitive),
                  let altMatch = altRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let altRange = Range(altMatch.range(at: 1), in: html) else {
                return nil
            }
            return String(html[altRange])
        }
        return String(html[range])
    }

    private static func extractFirstParagraph(from html: String) -> String? {
        // Lead lives near the top of the article body. Scanning the whole multi-MB page for every
        // tts-block is wasted work and used to stall resolution on long articles (Musk, etc.).
        let articleHTML: String
        if let markerRange = html.range(of: "<!-- Article body") {
            let tail = html[markerRange.lowerBound...]
            articleHTML = String(tail.prefix(120_000))
        } else {
            articleHTML = String(html.prefix(120_000))
        }

        // Grokipedia serves (at least) two article layouts:
        //   - older: the lead paragraph is the FIRST data-tts-block span after the marker;
        //   - newer: the infobox rows are ALSO tts-block spans ("Portrait, 2012", "Born …"), and the
        //     lead paragraph is a bare text node right after the infobox </div>, in no span at all.
        // So: collect the first body-paragraph-shaped candidate from each source and take whichever
        // appears earliest in the document (the lead always precedes later paragraphs).
        var candidates: [(position: Int, text: String)] = []

        let ttsPattern = #"data-tts-block="true"[^>]*>(.*?)</span>"#
        if let regex = try? NSRegularExpression(pattern: ttsPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(articleHTML.startIndex..., in: articleHTML)
            // A fat infobox can contribute a dozen-plus short spans before the first real paragraph.
            // Walk matches incrementally instead of materializing hundreds across the whole page.
            var matchCount = 0
            regex.enumerateMatches(in: articleHTML, options: [], range: range) { result, _, stop in
                guard let result, matchCount < 24 else {
                    stop.pointee = true
                    return
                }
                matchCount += 1
                guard let r = Range(result.range(at: 1), in: articleHTML) else { return }
                let text = stripHTML(String(articleHTML[r]))
                if isBodyParagraph(text) {
                    candidates.append((result.range.location, text))
                    stop.pointee = true
                }
            }
        }

        // Bare-text lead (newer layout). Stops at the first tag, which is fine: a lead that opens with
        // a link would be truncated, but such pages carry the lead in a tts span and win on position.
        let barePattern = #"</div>\s*([A-Z][^<>]{99,})"#
        if let regex = try? NSRegularExpression(pattern: barePattern, options: []) {
            let range = NSRange(articleHTML.startIndex..., in: articleHTML)
            var matchCount = 0
            regex.enumerateMatches(in: articleHTML, options: [], range: range) { result, _, stop in
                guard let result, matchCount < 8 else {
                    stop.pointee = true
                    return
                }
                matchCount += 1
                guard let r = Range(result.range(at: 1), in: articleHTML) else { return }
                let text = stripHTML(String(articleHTML[r]))
                if isBodyParagraph(text) {
                    candidates.append((result.range.location, text))
                    stop.pointee = true
                }
            }
        }

        if let lead = candidates.min(by: { $0.position < $1.position }) {
            return lead.text
        }

        for metaName in ["description", "og:description"] {
            let metaText: String?
            if metaName == "og:description" {
                metaText = extractMetaProperty(name: metaName, from: html)
            } else {
                metaText = extractMetaContent(named: metaName, from: html)
            }
            if let metaText {
                let text = stripHTML(metaText)
                if isPlausibleOpeningParagraph(text) {
                    return text
                }
            }
        }

        return nil
    }

    /// Stricter shape test used when scanning body candidates: infobox rows ("Born August 4, 1961
    /// (age 63) Honolulu, Hawaii, U.S.") satisfy the old 48-char floor, so a real body paragraph must
    /// be meaningfully longer AND read as prose (an internal sentence boundary). The looser
    /// `isPlausibleOpeningParagraph` is still what gates the meta-description fallback.
    private static func isBodyParagraph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 100, trimmed.contains(". ") else { return false }
        return isPlausibleOpeningParagraph(trimmed)
    }

    private static func isPlausibleOpeningParagraph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 48 else { return false }

        let lower = trimmed.lowercased()
        let chromeMarkers = [
            "interactive-widget=resizes-content",
            "<meta",
            "googletagmanager",
            " — grokipedia",
            " - grokipedia",
            "(function()",
        ]
        if chromeMarkers.contains(where: { lower.contains($0) }) {
            return false
        }

        return true
    }

    private static func extractTitle(from html: String, fallbackSlug: String) -> String {
        if let ogTitle = extractMetaProperty(name: "og:title", from: html) {
            let cleaned = ogTitle
                .replacingOccurrences(of: " — Grokipedia", with: "")
                .replacingOccurrences(of: " - Grokipedia", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }

        if let titleMatch = html.range(of: #"<title>(.*?)</title>"#, options: .regularExpression) {
            let fragment = String(html[titleMatch])
            let inner = fragment
                .replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: "</title>", with: "")
                .replacingOccurrences(of: " — Grokipedia", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { return inner }
        }

        return fallbackSlug.replacingOccurrences(of: "_", with: " ")
    }

    private static func extractArticleImage(from html: String) -> URL? {
        extractArticleImages(from: html).first
    }

    /// Ordered image candidates for the knowledge-panel banner. Grokipedia's `og:image` is often a
    /// soft/dark 16:9 lead (looks blurry at card size); body `<img>` tags with real dimensions are
    /// usually sharper. Prefer those first, then og/schema/infobox fallbacks.
    static func extractArticleImages(from html: String) -> [URL] {
        var ordered: [URL] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw, let url = normalizeImageURL(raw) else { return }
            if seen.insert(url.absoluteString).inserted {
                ordered.append(url)
            }
        }

        // Body images with width/height (first ~100KB after the article marker).
        let bodyScan: String
        if let marker = html.range(of: "<!-- Article body") {
            bodyScan = String(html[marker.lowerBound...].prefix(100_000))
        } else {
            bodyScan = String(html.prefix(100_000))
        }

        struct ScoredImage {
            let url: URL
            let score: Int
        }
        var scored: [ScoredImage] = []
        let imgTag = #"<img\b[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: imgTag, options: [.caseInsensitive]) {
            let range = NSRange(bodyScan.startIndex..., in: bodyScan)
            for match in regex.matches(in: bodyScan, range: range).prefix(20) {
                guard let r = Range(match.range, in: bodyScan) else { continue }
                let tag = String(bodyScan[r])
                guard let src = attributeValue("src", in: tag),
                      let url = normalizeImageURL(src) else { continue }
                let w = Int(attributeValue("width", in: tag) ?? "") ?? 0
                let h = Int(attributeValue("height", in: tag) ?? "") ?? 0
                // Prefer larger + more portrait-ish photos (entity cards read better with faces).
                var score = 0
                if w > 0, h > 0 {
                    score += min(w, 1200) + min(h, 1200)
                    if h >= w { score += 800 }           // portrait / square
                    if Double(w) / Double(max(h, 1)) > 1.6 { score -= 400 } // wide soft banners
                } else {
                    score += 100
                }
                scored.append(ScoredImage(url: url, score: score))
            }
        }
        for item in scored.sorted(by: { $0.score > $1.score }) {
            if seen.insert(item.url.absoluteString).inserted {
                ordered.append(item.url)
            }
        }

        // Meta / schema / pre-body infobox — kept as fallbacks after sharper body photos.
        append(extractMetaProperty(name: "og:image", from: html))
        append(extractSchemaOrgImage(from: html))
        append(extractInfoboxImage(from: html))

        return ordered
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        // Match name="…" or name='…' (case-insensitive attribute name).
        let pattern = name + #"\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[range])
    }

    /// Resolves a Grokipedia image reference to a loadable absolute URL, or nil when the article has no
    /// real image. Handles three shapes seen in the wild:
    ///   - relative article assets ("./_assets_/Foo.png") → the image CDN
    ///     (https://assets.grokipedia.com/wiki/images/Foo.png),
    ///   - absolute CDN/remote URLs → used as-is,
    ///   - grokipedia.com site chrome (e.g. "https://grokipedia.com/icon-512x512.png", returned as
    ///     og:image when an article has no lead image) → nil, so the caller falls back to SearXNG.
    static func normalizeImageURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Relative article asset reference → image CDN.
        if let range = trimmed.range(of: "_assets_/") {
            let filename = String(trimmed[range.upperBound...])
            guard !filename.isEmpty else { return nil }
            return URL(string: "https://assets.grokipedia.com/wiki/images/\(filename)")
        }

        let absolute: String
        if trimmed.hasPrefix("//") {
            absolute = "https:" + trimmed
        } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            absolute = trimmed
        } else {
            return nil
        }

        guard let url = URL(string: absolute), let host = url.host?.lowercased() else { return nil }

        // Real article images live on the assets CDN; a grokipedia.com-hosted image is site chrome
        // (favicon / app icon / logo), which means "no article image".
        if host == "grokipedia.com" || host == "www.grokipedia.com" {
            return nil
        }
        return url
    }

    private static func extractSchemaOrgImage(from html: String) -> String? {
        let pattern = #""@type"\s*:\s*"Article"[^}]*"image"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private static let skippedInfoboxLabels: Set<String> = [
        "registration required",
        "native client",
        "character limit",
        "current status",
        "area served",
        "former name",
        "former names",
        "rebranded date",
        "rebrand date",
    ]

    private static let infoboxLabelAliases: [String: String] = [
        "owner": "Owned by",
        "founders": "Founded by",
        "parent company": "Parent",
        "key people": "Key people",
        "launch date": "Launched",
        "website": "Website",
        "headquarters": "Headquarters",
        "industry": "Industry",
        "type": "Type",
        "products": "Products",
        "services": "Services",
        "founded": "Founded",
        "country": "Country",
        "acquisition date": "Acquired",
        "acquisition price": "Acquisition price",
        "ceo": "CEO",
    ]

    private static func extractInfoboxFacts(from html: String) -> [KnowledgeFact] {
        let marker = "<!-- Article body"
        guard let markerRange = html.range(of: marker) else { return [] }

        // Older layout: a <dl> infobox (dt/dd pairs) BEFORE the article-body marker.
        let infoboxHTML = String(html[..<markerRange.lowerBound])
        let dtDdPairs = rawFactPairs(
            in: infoboxHTML,
            pattern: #"<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>"#,
            limit: .max
        )
        if !dtDdPairs.isEmpty {
            return buildFacts(from: dtDdPairs)
        }

        // Newer layout: infobox rows are tts-block spans AFTER the marker, shaped
        // "<span data-tts-block="true" …><strong>Label</strong> value</span>". This markup is
        // AMBIGUOUS — bolded phrases in the article body match it too (verified live 2026-07-05: the
        // Elon Musk page's favorite-books list and its bolded lead sentence both parse as "facts"
        // here). So this fallback only trusts labels that look like real infobox fields; the dt/dd
        // path above is structurally an infobox and keeps every label.
        let bodyHTML = String(html[markerRange.lowerBound...])
        let strongPairs = rawFactPairs(
            in: bodyHTML,
            pattern: #"<span[^>]*data-tts-block="true"[^>]*>\s*<strong>(.*?)</strong>(.*?)</span>"#,
            limit: 40
        )
        return buildFacts(from: strongPairs, restrictToKnownLabels: true)
    }

    /// Infobox field names accepted from the ambiguous strong-span fallback (lowercased). Broad across
    /// entity kinds (people / orgs / places / products / media) but closed: an unknown "label" there is
    /// far more likely a bolded body phrase than a novel infobox field, and a wrong fact on the card is
    /// worse than a missing one (same precision-over-recall stance as the article relevance gate).
    private static let strongSpanFactLabels: Set<String> = [
        // People
        "born", "birth date", "birthplace", "birth place", "date of birth", "place of birth",
        "died", "death date", "death place", "nationality", "citizenship", "residence",
        "occupation", "occupations", "years active", "spouse", "spouses", "partner", "children",
        "parents", "relatives", "education", "alma mater", "known for", "title", "net worth",
        "height", "awards", "board memberships", "position", "party", "political party", "office",
        // Organizations
        "founded", "founder", "founders", "founded by", "launch date", "launched", "headquarters",
        "industry", "type", "products", "services", "key people", "ceo", "owner", "owned by",
        "parent", "parent company", "subsidiaries", "revenue", "employees", "number of employees",
        "website", "official website", "acquisition date", "acquisition price", "traded as", "status",
        // Places
        "country", "capital", "population", "area", "region", "state", "province", "mayor",
        "government", "time zone", "timezone", "elevation", "demonym", "official language",
        "official languages", "languages", "language", "currency", "established",
        // Products / media / works
        "developer", "developers", "publisher", "publishers", "author", "authors", "director",
        "directors", "producer", "starring", "genre", "genres", "release date", "released",
        "initial release", "latest release", "platform", "platforms", "license", "engine", "version",
        "programming language", "operating system", "written by", "composer", "created by",
        "country of origin", "original language", "budget", "box office", "running time", "based on",
        "pages", "isbn", "predecessor", "successor", "motto", "formation", "purpose", "named after",
    ]

    private static func rawFactPairs(in html: String, pattern: String, limit: Int) -> [(label: String, value: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var pairs: [(label: String, value: String)] = []
        for match in regex.matches(in: html, range: range).prefix(limit) {
            guard match.numberOfRanges >= 3,
                  let labelRange = Range(match.range(at: 1), in: html),
                  let valueRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            pairs.append((String(html[labelRange]), String(html[valueRange])))
        }
        return pairs
    }

    private static func buildFacts(from rawPairs: [(label: String, value: String)],
                                   restrictToKnownLabels: Bool = false) -> [KnowledgeFact] {
        var facts: [KnowledgeFact] = []
        var seenLabels = Set<String>()

        for pair in rawPairs {
            let rawLabel = stripHTML(pair.label)
            let rawValue = normalizeInfoboxValue(stripHTML(pair.value))
            guard rawLabel.count >= 2, rawValue.count >= 2 else { continue }
            // Infobox labels are short noun phrases; a long or sentence-like "label" is a bolded
            // phrase from the article body that happened to match (strong-span layout only).
            guard rawLabel.count <= 28, !rawLabel.contains(".") else { continue }

            let normalizedKey = rawLabel.lowercased()
            guard !skippedInfoboxLabels.contains(normalizedKey) else { continue }
            if restrictToKnownLabels {
                // Strong-span fallback only: unknown labels are bolded body phrases, and a value that
                // opens with "(" is the bolded lead sentence ("**Elon Reeve Musk** (born June 28, …)").
                guard strongSpanFactLabels.contains(normalizedKey), !rawValue.hasPrefix("(") else { continue }
            }

            let displayLabel = infoboxLabelAliases[normalizedKey] ?? rawLabel
            let dedupeKey = displayLabel.lowercased()
            guard seenLabels.insert(dedupeKey).inserted else { continue }

            facts.append(KnowledgeFact(label: displayLabel, value: rawValue))
        }

        return facts
    }

    private static func normalizeInfoboxValue(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let regex = try? NSRegularExpression(pattern: #"([a-z])([A-Z])"#, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 $2")
        }

        if text.count > 240 {
            text = String(text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func extractInfoboxImage(from html: String) -> String? {
        let marker = "<!-- Article body"
        guard let markerRange = html.range(of: marker) else { return nil }
        let prefix = String(html[..<markerRange.lowerBound])

        let pattern = #"https://assets\.grokipedia\.com/wiki/images/[A-Za-z0-9._-]+\.(?:jpg|jpeg|png|webp)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let range = Range(match.range, in: prefix) else {
            return nil
        }
        return String(prefix[range])
    }

    private static func extractMetaProperty(name: String, from html: String) -> String? {
        let pattern = #"<meta[^>]+property="\#(name)"[^>]+content="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            let altPattern = #"<meta[^>]+content="([^"]*)"[^>]+property="\#(name)""#
            guard let altRegex = try? NSRegularExpression(pattern: altPattern, options: .caseInsensitive),
                  let altMatch = altRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let altRange = Range(altMatch.range(at: 1), in: html) else {
                return nil
            }
            return String(html[altRange])
        }
        return String(html[range])
    }

    private static func extractMetaContent(named name: String, from html: String) -> String? {
        let pattern = #"<meta[^>]+name="\#(name)"[^>]+content="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }

        guard let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return cleanupSpacing(text)
        }
        let range = NSRange(text.startIndex..., in: text)
        text = tagRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        return cleanupSpacing(text)
    }

    /// Tidies text recovered from HTML: drops inline citation markers ("[1]"), removes the spurious
    /// spaces that tag-stripping leaves in front of punctuation ("sugar , cinnamon" → "sugar, cinnamon"),
    /// and collapses runs of whitespace. Centralized so both the opening paragraph and infobox values
    /// render cleanly.
    static func cleanupSpacing(_ input: String) -> String {
        var text = input

        // Markdown / wiki link syntax that Grokipedia leaves in some infobox values and paragraphs:
        //   [Elon Musk](/Elon_Musk)                    → Elon Musk
        //   [[#Anchor|Establishment and Key Figures]]  → Establishment and Key Figures
        //   [[Foo]]                                    → Foo
        // Wiki links first (they contain brackets the markdown rule shouldn't touch).
        let linkPatterns: [(pattern: String, template: String)] = [
            (#"\[\[(?:[^\]|]*\|)?([^\]]+)\]\]"#, "$1"),
            (#"\[([^\]\[]+)\]\([^)]*\)"#, "$1"),
        ]
        for (pattern, template) in linkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
                )
            }
        }

        // Inline citation markers like [1], [12], [citation needed].
        let citationPatterns = [#"\[\d{1,3}\]"#, #"\[(?:citation needed|note \d+)\]"#]
        for pattern in citationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
                )
            }
        }

        // Space(s) before sentence punctuation, left behind when inline tags became spaces.
        if let punctRegex = try? NSRegularExpression(pattern: #"\s+([,.;:!?%)])"#) {
            text = punctRegex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
            )
        }

        // Space after an opening parenthesis.
        text = text.replacingOccurrences(of: "( ", with: "(")

        // Collapse ALL whitespace runs (incl. newlines — HTML source formatting, not content) to a
        // single space. Newlines used to survive here, which both rendered oddly on the card and made
        // ".\n" sentence boundaries invisible to the ". " prose check in isBodyParagraph.
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}