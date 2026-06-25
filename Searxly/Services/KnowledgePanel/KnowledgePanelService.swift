//
//  KnowledgePanelService.swift
//  Searxly
//
//  Knowledge panel resolver — Grokipedia articles only (direct HTML fetch).
//

import Foundation

enum KnowledgePanelService {

    static func resolve(query: String) async -> KnowledgePanelContent? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard KnowledgeQueryDetector.classify(trimmed) == .entity else { return nil }

        let entity = bestEntity(for: trimmed)
        let subject = displaySubject(from: trimmed, entity: entity)
        guard let (slug, snippet) = await resolveArticle(for: trimmed, entity: entity) else {
            return nil
        }

        let paragraph = snippet.firstParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.count >= 48 else { return nil }

        var entityKind = entity?.entityKind
        if entityKind == nil, looksLikePersonName(subject) {
            entityKind = .person
        }

        let officialSite = officialSiteInfo(for: entity)
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? subject : title

        let panel = EntityPanelData(
            title: displayTitle,
            aboutParagraphs: [paragraph],
            entityKind: entityKind,
            officialSiteURL: officialSite?.url,
            officialSiteLabel: officialSite?.label,
            grokipediaURL: GrokipediaSlugCatalog.pageURL(for: slug),
            grokipediaBannerURL: snippet.imageURL,
            facts: Array(snippet.facts.prefix(12))
        )

        return KnowledgePanelContent(query: trimmed, kind: .entity(panel))
    }

    // MARK: - Entity matching

    private static func bestEntity(for query: String) -> OfficialEntityDatabase.OfficialEntity? {
        let subject = strippedSubject(from: query)
        if let entity = OfficialEntityDatabase.entity(for: subject) {
            return entity
        }

        if let url = OfficialEntityDatabase.fuzzyMatchURL(for: subject) {
            return OfficialEntityDatabase.all.first { $0.primaryURL == url }
        }

        return nil
    }

    /// Finds a Grokipedia article for the query by trying slug candidates in order of confidence,
    /// returning the first that yields a real article. Two phases so common (curated) entities never
    /// pay for the Wikipedia resolution:
    ///   1. Curated/verified + naive-inferred slugs (no extra network for resolution).
    ///   2. Wikipedia opensearch → canonical titles → slugs (covers the long tail; only when 1 misses).
    private static func resolveArticle(
        for query: String,
        entity: OfficialEntityDatabase.OfficialEntity?
    ) async -> (slug: String, snippet: GrokipediaArticleSnippet)? {
        let subject = strippedSubject(from: query)
        var tried = Set<String>()

        func attempt(_ slug: String?) async -> (String, GrokipediaArticleSnippet)? {
            guard let slug, !slug.isEmpty, tried.insert(slug).inserted else { return nil }
            if let snippet = await GrokipediaArticleClient.fetchFirstParagraph(slug: slug) {
                return (slug, snippet)
            }
            return nil
        }

        // Phase 1: curated + naive-inferred (fast path for the well-known entities).
        if let hit = await attempt(GrokipediaSlugCatalog.slug(for: entity)) { return hit }
        if let hit = await attempt(GrokipediaSlugCatalog.slug(forSubject: subject)) { return hit }

        // Phase 2: Wikipedia-resolved canonical titles (the long tail, e.g. "torproject").
        for title in await WikipediaTitleResolver.canonicalTitles(for: subject) {
            let slug = title.replacingOccurrences(of: " ", with: "_")
            if let hit = await attempt(slug) { return hit }
        }

        return nil
    }

    private static func strippedSubject(from query: String) -> String {
        var s = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["who is ", "who's ", "who was ", "what is ", "what's ", "tell me about "]
        for p in prefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func looksLikePersonName(_ subject: String) -> Bool {
        let tokens = subject
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard tokens.count >= 2, tokens.count <= 4 else { return false }
        let skip = Set(["the", "of", "and", "inc", "corp", "company", "official", "ltd", "llc"])
        return tokens.allSatisfy { token in
            !skip.contains(token) &&
            token.rangeOfCharacter(from: .letters) != nil &&
            token.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
        }
    }

    private static func officialSiteInfo(
        for entity: OfficialEntityDatabase.OfficialEntity?
    ) -> (url: String, label: String)? {
        guard let entity, let host = URL(string: entity.primaryURL)?.host else { return nil }
        let cleanHost = host.replacingOccurrences(of: "www.", with: "")
        return (entity.primaryURL, cleanHost)
    }
}