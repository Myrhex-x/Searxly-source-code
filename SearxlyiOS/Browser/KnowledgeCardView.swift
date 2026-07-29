//
//  KnowledgeCardView.swift
//  SearxlyiOS
//
//  A Wikipedia knowledge card pinned above web results for entity queries ("nikola tesla",
//  "black hole") — the iOS take on the macOS knowledge panel. One anonymous REST summary fetch
//  per matching search (ephemeral session, no cookies), gated by Settings ▸ Search ▸ Knowledge
//  Cards and skipped entirely in private tabs. The card renders only when Wikipedia's resolved
//  title genuinely matches the query, so junk queries never produce a confident-looking card.
//

import SwiftUI
import UIKit

struct KnowledgeCard: Equatable {
    enum Source: String {
        case wikipedia = "Wikipedia"
        case grokipedia = "Grokipedia"
    }

    let source: Source
    let title: String
    let extract: String
    let thumbnail: URL?
    let pageURL: URL
    var facts: [KnowledgeFact] = []
}

enum KnowledgeCardService {

    /// In-memory per-session cache (query → card or confirmed miss).
    @MainActor private static var cache: [String: KnowledgeCard?] = [:]

    @MainActor
    static func card(for query: String, language: String) async -> KnowledgeCard? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEntityLike(q) else { return nil }
        if let hit = cache[q.lowercased()] { return hit }

        // Resolve any tag (including "auto") to a real Wikipedia language — system/app default,
        // never hard-coded English unless the device itself is English.
        let lang = AppLocale.wikipediaCode(
            for: (language == "auto" || language.isEmpty)
                ? AppLocale.shared.languageCode
                : language
        )
        var card = await fetchSummary(query: q, language: lang)

        // Grokipedia is the DEFAULT source (macOS SERP source policy). Slug preference:
        // the Wikipedia-resolved canonical title (clean typo rescue) — but when Wikipedia
        // has nothing, still try Grokipedia directly from the title-cased query, so its
        // coverage doesn't depend on Wikipedia resolving first.
        if ShieldSettings.shared.preferGrokipedia {
            // Slug candidates, best first. Grokipedia mirrors Wikipedia titling: proper nouns are
            // title-case ("Nikola Tesla"), topics are sentence-case ("Quantum computing").
            var slugs = [card?.title, sentenceCased(q), titleCased(q)].compactMap { $0 }
            slugs = slugs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

            for slug in slugs {
                if let grok = await GrokipediaCardClient.fetch(slug: slug) {
                    card = KnowledgeCard(
                        source: .grokipedia,
                        title: grok.title,
                        extract: grok.paragraph,
                        thumbnail: grok.image ?? card?.thumbnail,  // wiki portrait fills in when the article has none
                        pageURL: grok.pageURL,
                        facts: grok.facts
                    )
                    break
                }
            }
        }

        cache[q.lowercased()] = card
        return card
    }

    /// "quantum computing" → "Quantum computing".
    private static func sentenceCased(_ q: String) -> String {
        q.prefix(1).uppercased() + q.dropFirst().lowercased()
    }

    /// "nikola tesla" → "Nikola Tesla".
    private static func titleCased(_ q: String) -> String {
        q.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Cheap entity heuristic: 1–4 plain words, no operators/URLs/questions.
    private static func isEntityLike(_ q: String) -> Bool {
        guard !q.isEmpty, q.count <= 40, !q.contains("."), !q.contains(":"), !q.contains("?") else { return false }
        let words = q.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        return q.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" }
    }

    private static func fetchSummary(query: String, language: String) async -> KnowledgeCard? {
        let title = query.replacingOccurrences(of: " ", with: "_")
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encoded)?redirect=true")
        else { return nil }

        let config = URLSessionConfiguration.ephemeral  // no cookies, nothing shared
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "standard",
              let resolvedTitle = json["title"] as? String,
              let extract = json["extract"] as? String, extract.count > 40,
              titlesMatch(query, resolvedTitle),
              let content = json["content_urls"] as? [String: Any],
              let mobile = content["mobile"] as? [String: Any],
              let pageStr = mobile["page"] as? String,
              let pageURL = URL(string: pageStr)
        else { return nil }

        let thumb = ((json["thumbnail"] as? [String: Any])?["source"] as? String).flatMap(URL.init(string:))
        return KnowledgeCard(source: .wikipedia, title: resolvedTitle, extract: extract,
                             thumbnail: thumb, pageURL: pageURL)
    }

    /// The resolved article must BE the query (after case/diacritic folding), not merely related.
    private static func titlesMatch(_ query: String, _ title: String) -> Bool {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ").joined(separator: " ")
        }
        return fold(query) == fold(title)
    }
}

// MARK: - Card view

struct KnowledgeCardView: View {
    let card: KnowledgeCard
    let onOpen: (URL) -> Void

    @State private var thumb: UIImage?
    private var appearance = AppearanceSettings.shared
    private var locale = AppLocale.shared

    init(card: KnowledgeCard, onOpen: @escaping (URL) -> Void) {
        self.card = card
        self.onOpen = onOpen
    }

    @State private var expanded = false

    var body: some View {
        let _ = locale.languageCode
        let scale = appearance.textScale
        let sourceName = L(card.source.rawValue)
        VStack(alignment: .leading, spacing: 0) {
            // Tap the card body to expand/collapse (Google-style); the footer row opens the article.
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
                Haptics.tick()
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 13) {
                        if card.thumbnail != nil {
                            ZStack {
                                Brand.surfaceHi
                                if let thumb {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                }
                            }
                            .frame(width: expanded ? 92 : 74, height: expanded ? 92 : 74)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(card.title)
                                    .font(.system(size: 18 * scale, weight: .bold))
                                    .foregroundStyle(Brand.text)
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.down")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(Brand.textTertiary)
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            Text(card.extract)
                                .font(.system(size: 13 * scale))
                                .foregroundStyle(Brand.textSecondary)
                                .lineLimit(expanded ? nil : 4)
                        }
                    }

                    // Infobox facts (Born, Founded, …) — Grokipedia cards only, when expanded.
                    if expanded && !card.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(card.facts.prefix(6)) { fact in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(fact.label)
                                        .font(.system(size: 12 * scale, weight: .semibold))
                                        .foregroundStyle(Brand.textTertiary)
                                        .frame(width: 96, alignment: .leading)
                                    Text(fact.value)
                                        .font(.system(size: 12 * scale))
                                        .foregroundStyle(Brand.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Attribution + open-article affordance.
            Button { onOpen(card.pageURL) } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "\(L("Read on")) \(sourceName)" : sourceName)
                        .font(.system(size: 11 * scale, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .scaledFont(size: 9, weight: .semibold)
                }
                .foregroundStyle(Brand.textTertiary)
                .padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(L("Read on")) \(sourceName)")
        }
        .padding(12)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .task(id: card.thumbnail) {
            guard let url = card.thumbnail else { return }
            thumb = await RemoteThumbLoader.load(candidates: [url], referer: nil)
        }
        .accessibilityLabel("\(L("Knowledge card")): \(card.title)")
    }
}
