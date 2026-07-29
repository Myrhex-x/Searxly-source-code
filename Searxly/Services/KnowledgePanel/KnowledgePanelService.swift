//
//  KnowledgePanelService.swift
//  Searxly
//
//  Knowledge panel resolver — Grokipedia articles only (direct HTML fetch).
//

import Foundation

enum KnowledgePanelService {

    static func resolve(query: String, imageInstanceURL: String? = nil) async -> KnowledgePanelContent? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Accept both entity and single-word ("dictionary") candidates: there is no separate
        // dictionary-card UI, and the relevance gate ensures a card only renders when Grokipedia
        // actually has a matching article. This is what lets single-word entities — "bitcoin",
        // "tokyo", "mozart" — get a card instead of being silently dropped.
        guard KnowledgeQueryDetector.classify(trimmed) != .none else { return nil }

        // Serve from the per-query cache when fresh (instant re-show; avoids re-resolving misses).
        if let cached = cachedResult(for: trimmed) {
            return cached.content
        }

        let (result, cacheable) = await resolveUncached(query: trimmed, imageInstanceURL: imageInstanceURL)
        // Positive results always cache. A nil is cached (negative TTL) ONLY when every article lookup
        // failed deterministically — a transient failure (network blip, Grokipedia rate limit) must not
        // pin "no card" for 5 minutes; the next search just resolves again.
        if cacheable { storeResult(result, for: trimmed) }
        return result
    }

    private static func resolveUncached(query trimmed: String, imageInstanceURL: String?) async -> (content: KnowledgePanelContent?, cacheable: Bool) {
        let entity = bestEntity(for: trimmed)
        let subject = displaySubject(from: trimmed, entity: entity)
        let resolution = await resolveArticle(for: trimmed, entity: entity)
        guard let (slug, snippet) = resolution.hit else {
            return (nil, !resolution.sawTransientFailure)
        }

        let paragraph = snippet.firstParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.count >= 48 else { return (nil, true) }   // deterministic content shape

        var entityKind = entity?.entityKind
        if entityKind == nil, articleDescribesPerson(facts: snippet.facts) {
            entityKind = .person
        }

        let officialSite = officialSiteInfo(for: entity)
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? subject : title

        let (bannerCandidates, bannerReferer) = await resolveBannerImage(
            grokipediaImages: snippet.imageURLs,
            subject: displayTitle,
            entity: entity,
            instanceURL: imageInstanceURL
        )

        let panel = EntityPanelData(
            title: displayTitle,
            aboutParagraphs: [paragraph],
            entityKind: entityKind,
            officialSiteURL: officialSite?.url,
            officialSiteLabel: officialSite?.label,
            grokipediaURL: GrokipediaSlugCatalog.pageURL(for: slug),
            bannerImageCandidates: bannerCandidates,
            bannerImageReferer: bannerReferer,
            facts: Array(snippet.facts.prefix(12))
        )

        return (KnowledgePanelContent(query: trimmed, kind: .entity(panel)), true)
    }

    /// Picks the banner image. Order of preference:
    ///   1. Bundled celebrity face (sharp offline portraits for known people — Grokipedia's og:image
    ///      is often a soft 16:9 lead that looks blurry at card size).
    ///   2. Ordered Grokipedia article images (body photos first, og:image last).
    ///   3. SearXNG image search fallback (private; reuses image_proxy for hotlink protection).
    private static func resolveBannerImage(
        grokipediaImages: [URL],
        subject: String,
        entity: OfficialEntityDatabase.OfficialEntity?,
        instanceURL: String?
    ) async -> (candidates: [URL], referer: String?) {
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            if seen.insert(url.absoluteString).inserted {
                candidates.append(url)
            }
        }

        // Offline portrait first for curated people (Resources/CelebrityFaces/*.jpg).
        append(bundledCelebrityFaceURL(for: entity))

        for url in grokipediaImages {
            append(url)
        }

        if !candidates.isEmpty {
            // Bundled faces are file:// (referer unused). CDN images want the article host.
            let referer = candidates.contains(where: { !$0.isFileURL }) ? "https://grokipedia.com" : nil
            return (candidates, referer)
        }

        guard let instanceURL,
              let result = await SearXNGImageResolver.firstImageResult(for: subject, instanceURL: instanceURL)
        else {
            return ([], nil)
        }
        let remote = SearchMediaURLResolver.candidateURLs(
            for: result, proxyBase: instanceURL, mode: .gridThumbnail
        )
        return (remote, result.url)
    }

    /// Bundled face for a curated person entity (`celebrityFaceSlug` → Resources/{slug}.jpg).
    private static func bundledCelebrityFaceURL(
        for entity: OfficialEntityDatabase.OfficialEntity?
    ) -> URL? {
        guard let slug = entity?.celebrityFaceSlug, !slug.isEmpty else { return nil }
        let bundle = Bundle.main
        if let url = bundle.url(forResource: slug, withExtension: "jpg") { return url }
        if let url = bundle.url(forResource: slug, withExtension: "jpeg") { return url }
        if let url = bundle.url(forResource: slug, withExtension: "png") { return url }
        // Folder-style copy (CelebrityFaces/{slug}.jpg) if the resource group kept its path.
        if let url = bundle.url(forResource: slug, withExtension: "jpg", subdirectory: "CelebrityFaces") {
            return url
        }
        return nil
    }

    // MARK: - Result cache

    private struct CachedPanel {
        let content: KnowledgePanelContent?
        let storedAt: Date
    }

    private static var resultCache: [String: CachedPanel] = [:]
    private static let resultCacheLock = NSLock()
    /// Cards are stable for hours; misses expire quickly so a transient outage self-heals on retry.
    private static let positiveTTL: TimeInterval = 2 * 60 * 60
    private static let negativeTTL: TimeInterval = 5 * 60
    private static let maxResultCacheEntries = 128

    private static func cacheKey(_ query: String) -> String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cachedResult(for query: String) -> CachedPanel? {
        let key = cacheKey(query)
        resultCacheLock.lock()
        defer { resultCacheLock.unlock() }
        guard let entry = resultCache[key] else { return nil }
        let ttl = entry.content == nil ? negativeTTL : positiveTTL
        if Date().timeIntervalSince(entry.storedAt) > ttl {
            resultCache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private static func storeResult(_ content: KnowledgePanelContent?, for query: String) {
        resultCacheLock.lock()
        defer { resultCacheLock.unlock() }
        if resultCache.count >= maxResultCacheEntries,
           let oldest = resultCache.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            resultCache.removeValue(forKey: oldest)
        }
        resultCache[cacheKey(query)] = CachedPanel(content: content, storedAt: Date())
    }

    // MARK: - Entity matching

    /// Resolves the query to a curated entity, but ONLY via a strong (exact canonical/alias) match.
    /// The matching itself lives in the shared `EntityQueryMatcher` (also used by the SERP ranker on
    /// both platforms); see the rationale there for why fuzzy matching is deliberately avoided.
    static func bestEntity(for query: String) -> OfficialEntityDatabase.OfficialEntity? {
        EntityQueryMatcher.bestEntity(for: query)
    }

    // MARK: - Relevance gate

    /// Lowercased, punctuation-free, noise-word-free tokens. Used for both query subjects and article
    /// titles/slugs so they can be compared on equal footing.
    static func significantTokens(_ string: String) -> [String] {
        EntityQueryMatcher.significantTokens(string)
    }

    /// Whether a fetched article is plausibly *about* the query subject. Applied to inferred /
    /// Wikipedia-derived slugs (curated matches skip this — e.g. "grok" legitimately resolves to "xAI",
    /// which shares no token with the query). Conservative by design: a card is far worse when wrong
    /// than when absent.
    ///
    /// Accepts when:
    ///  - every significant query token appears in the article title/slug (the article covers the
    ///    whole query, e.g. "tor" ⊆ {tor, project}); or
    ///  - the de-spaced query equals the de-spaced title or slug (handles concatenated single-word
    ///    queries like "torproject" == "tor project", "stackoverflow" == "stack overflow").
    static func isArticleRelevant(subject: String, slug: String, snippet: GrokipediaArticleSnippet) -> Bool {
        let titleSource = snippet.title.isEmpty
            ? slug.replacingOccurrences(of: "_", with: " ")
            : snippet.title
        let titleTokens = significantTokens(titleSource)
        let slugTokens = significantTokens(slug.replacingOccurrences(of: "_", with: " "))
        return subjectMatchesArticle(subject: subject, articleTokenGroups: [titleTokens, slugTokens])
    }

    /// Cheap pre-fetch relevance check used to skip Wikipedia candidates that can't be about the query
    /// before paying for a network fetch (the post-fetch `isArticleRelevant` is the authoritative gate).
    static func isTitleRelevant(subject: String, title: String) -> Bool {
        subjectMatchesArticle(subject: subject, articleTokenGroups: [significantTokens(title)])
    }

    /// Core relevance rule shared by the pre- and post-fetch checks. Accepts when every significant query
    /// token appears in one of the article's token groups AND that group adds at most one extra token
    /// ("tor" → "Tor Project" ok, "barack obama" → "Barack Obama 2008 Presidential Campaign" NOT — a
    /// plain-subset rule used to let those wrong sub-topic articles render as the entity's card), or
    /// when the de-spaced query equals one token group de-spaced ("torproject" == "tor project").
    private static func subjectMatchesArticle(subject: String, articleTokenGroups: [[String]]) -> Bool {
        let queryTokens = significantTokens(subject)
        guard !queryTokens.isEmpty else { return false }

        let querySet = Set(queryTokens)
        for group in articleTokenGroups where !group.isEmpty {
            if querySet.isSubset(of: Set(group)) && group.count <= queryTokens.count + 1 {
                return true
            }
        }

        let queryConcat = queryTokens.joined()
        if !queryConcat.isEmpty, articleTokenGroups.contains(where: { $0.joined() == queryConcat }) {
            return true
        }

        return false
    }

    /// Finds a Grokipedia article for the query by trying slug candidates in order of confidence,
    /// returning the first that yields a real article. Two phases so common (curated) entities never
    /// pay for the Wikipedia resolution:
    ///   1. Curated/verified + naive-inferred slugs (no extra network for resolution).
    ///   2. Wikipedia opensearch → canonical titles → slugs (covers the long tail; only when 1 misses).
    private static func resolveArticle(
        for query: String,
        entity: OfficialEntityDatabase.OfficialEntity?
    ) async -> (hit: (slug: String, snippet: GrokipediaArticleSnippet)?, sawTransientFailure: Bool) {
        let subject = strippedSubject(from: query)
        var tried = Set<String>()
        // Whether ANY fetch failed transiently (network / kill switch / rate-limit blip). The caller
        // uses this to skip negative-caching: with a transient miss in the mix, "no article" was never
        // actually established.
        var sawTransient = false

        /// Fetches the slug's article and returns it only when we can trust the match: either the slug
        /// came from a curated source (`trusted: true`), or the fetched article passes the relevance
        /// gate against the query subject. This prevents an inferred/Wikipedia slug from rendering an
        /// article that has nothing to do with what the user typed.
        func attempt(_ slug: String?, trusted: Bool) async -> (String, GrokipediaArticleSnippet)? {
            guard let slug, !slug.isEmpty, tried.insert(slug).inserted else { return nil }
            let snippet: GrokipediaArticleSnippet
            switch await GrokipediaArticleClient.fetchOutcome(slug: slug) {
            case .article(let fetched): snippet = fetched
            case .notFound:             return nil
            case .transient:            sawTransient = true; return nil
            }
            guard trusted || isArticleRelevant(subject: subject, slug: slug, snippet: snippet) else {
                return nil
            }
            return (slug, snippet)
        }

        // Phase 1a: curated entity slug — `entity` only comes from a strong (exact/alias) match, so trust it.
        if let hit = await attempt(GrokipediaSlugCatalog.slug(for: entity), trusted: true) { return (hit, sawTransient) }

        // Phase 1b: subject → slug. Trust it only when it's an explicit catalog/alias hit; a naive
        // Title_Case-inferred slug ("Cool_Ai") is NOT trusted and must pass the relevance gate.
        let subjectSlug = GrokipediaSlugCatalog.slug(forSubject: subject)
        let subjectTrusted = GrokipediaSlugCatalog.hasExplicitSlug(for: subject)
            || OfficialEntityDatabase.entity(for: subject) != nil
        if let hit = await attempt(subjectSlug, trusted: subjectTrusted) { return (hit, sawTransient) }

        // Phase 2: Wikipedia-resolved canonical titles (the long tail, e.g. "torproject").
        // Always untrusted — opensearch returns loosely-related titles, so the relevance gate decides.
        // Pre-filter by title relevance first so we never spend a network fetch on an unrelated result.
        let wikipediaTitles = await WikipediaTitleResolver.canonicalTitles(for: subject)
        for title in wikipediaTitles {
            guard isTitleRelevant(subject: subject, title: title) else { continue }
            let slug = title.replacingOccurrences(of: " ", with: "_")
            if let hit = await attempt(slug, trusted: false) { return (hit, sawTransient) }
        }

        // Phase 3: typo rescue. Wikipedia's opensearch is typo-tolerant — its FIRST suggestion for a
        // misspelled entity is usually the correction ("elon muskk" → "Elon Musk"), which the token
        // gate above rightly rejects (the typo'd token matches nothing). Accept that one suggestion
        // only when the whole title is a near-verbatim match for what was typed — the tiny edit
        // distance IS the relevance proof, so the fetched article is trusted.
        if let correction = wikipediaTitles.first, isLikelyTypoCorrection(subject: subject, title: correction) {
            let slug = correction.replacingOccurrences(of: " ", with: "_")
            if let hit = await attempt(slug, trusted: true) { return (hit, sawTransient) }
        }

        return (nil, sawTransient)
    }

    /// Whether `title` reads as a spelling correction of `subject`: compared over significant tokens
    /// (case/punctuation-insensitive), within an edit distance small in absolute terms AND relative to
    /// the query length, so short queries can't "correct" into unrelated words.
    static func isLikelyTypoCorrection(subject: String, title: String) -> Bool {
        let a = significantTokens(subject).joined(separator: " ")
        let b = significantTokens(title).joined(separator: " ")
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        let distance = editDistance(a, b)
        return distance <= 2 && distance <= max(1, a.count / 5)
    }

    /// Plain Levenshtein distance; inputs here are short normalized queries/titles, so O(n·m) is fine.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func strippedSubject(from query: String) -> String {
        EntityQueryMatcher.strippedSubject(from: query)
    }

    private static func displaySubject(
        from query: String,
        entity: OfficialEntityDatabase.OfficialEntity?
    ) -> String {
        if let entity {
            return entity.canonicalKey.split(separator: " ").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }
        return strippedSubject(from: query).split(separator: " ").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    /// Person labels for biographical infobox fields. Using the *article's* facts (not the query's
    /// word shape) prevents non-people from being tagged "Person" — e.g. "apple pie" (a dessert) used
    /// to be labelled a person purely because it was two lowercase words.
    private static let personFactLabels: Set<String> = [
        "born", "birth date", "birthplace", "birth place", "date of birth", "place of birth",
        "died", "death date", "nationality", "occupation", "spouse", "spouses",
        "children", "education", "alma mater", "known for", "years active", "partner"
    ]

    static func articleDescribesPerson(facts: [KnowledgeFact]) -> Bool {
        facts.contains { personFactLabels.contains($0.label.lowercased()) }
    }

    private static func officialSiteInfo(
        for entity: OfficialEntityDatabase.OfficialEntity?
    ) -> (url: String, label: String)? {
        guard let entity, let host = URL(string: entity.primaryURL)?.host else { return nil }
        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
        return (entity.primaryURL, cleanHost)
    }
}