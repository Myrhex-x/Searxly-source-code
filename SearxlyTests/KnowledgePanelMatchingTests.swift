//
//  KnowledgePanelMatchingTests.swift
//  SearxlyTests
//
//  Guards the knowledge-panel matching pipeline against confidently-wrong cards. The motivating bug:
//  any query containing the word "ai" ("is ai safe", "cool ai") rendered the xAI article, because the
//  panel reused the agent's loose `fuzzyMatchURL` (a single shared 2+ char token counted as a hit, and
//  the "x ai" alias collapsed to {"ai"}). These tests pin the two fixes: strict entity matching, and a
//  relevance gate on inferred / long-tail slugs.
//

import XCTest
@testable import Searxly

final class KnowledgePanelMatchingTests: XCTestCase {

    // MARK: - Strict entity matching (no loose fuzzy)

    func testExactBrandsStillResolve() {
        XCTAssertEqual(KnowledgePanelService.bestEntity(for: "xai")?.canonicalKey, "xai")
        XCTAssertEqual(KnowledgePanelService.bestEntity(for: "apple")?.canonicalKey, "apple")
        XCTAssertEqual(KnowledgePanelService.bestEntity(for: "elon musk")?.canonicalKey, "elon musk")
        // Question phrasing is stripped before lookup.
        XCTAssertEqual(KnowledgePanelService.bestEntity(for: "who is elon musk")?.canonicalKey, "elon musk")
        // Trailing noise words are tolerated.
        XCTAssertEqual(KnowledgePanelService.bestEntity(for: "apple official site")?.canonicalKey, "apple")
    }

    func testLooseQueriesNoLongerMatchEntities() {
        // The reported bug: any "ai"-containing phrase used to resolve to xAI / OpenAI.
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "is ai safe"))
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "cool ai tools"))
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "ai"))
        // Other single-token collisions the old fuzzy matcher produced.
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "treasure maps"))
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "site survey"))
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "app"))
        XCTAssertNil(KnowledgePanelService.bestEntity(for: "official report"))
    }

    // MARK: - Relevance gate

    private func snippet(title: String) -> GrokipediaArticleSnippet {
        GrokipediaArticleSnippet(
            title: title,
            firstParagraph: String(repeating: "x", count: 60),
            pageURL: "https://grokipedia.com/page/test",
            imageURL: nil,
            facts: []
        )
    }

    func testRelevanceGateRejectsUnrelatedArticle() {
        // "cool ai" must NOT be accepted as the xAI article.
        XCTAssertFalse(KnowledgePanelService.isArticleRelevant(
            subject: "cool ai",
            slug: "XAI_(company)",
            snippet: snippet(title: "xAI")
        ))
        XCTAssertFalse(KnowledgePanelService.isArticleRelevant(
            subject: "is ai safe",
            slug: "OpenAI",
            snippet: snippet(title: "OpenAI")
        ))
    }

    func testRelevanceGateAcceptsGenuineLongTail() {
        // Article covers every query token.
        XCTAssertTrue(KnowledgePanelService.isArticleRelevant(
            subject: "ada lovelace",
            slug: "Ada_Lovelace",
            snippet: snippet(title: "Ada Lovelace")
        ))
        // Single query token contained by the title's tokens.
        XCTAssertTrue(KnowledgePanelService.isArticleRelevant(
            subject: "tor",
            slug: "The_Tor_Project",
            snippet: snippet(title: "The Tor Project")
        ))
        // Concatenated single-word query equals the de-spaced title (documented "torproject" case).
        XCTAssertTrue(KnowledgePanelService.isArticleRelevant(
            subject: "torproject",
            slug: "The_Tor_Project",
            snippet: snippet(title: "The Tor Project")
        ))
        XCTAssertTrue(KnowledgePanelService.isArticleRelevant(
            subject: "stackoverflow",
            slug: "Stack_Overflow",
            snippet: snippet(title: "Stack Overflow")
        ))
    }

    func testTitlePrefilterRelevance() {
        // Pre-fetch filter: keep genuinely-related Wikipedia titles, drop unrelated ones.
        XCTAssertTrue(KnowledgePanelService.isTitleRelevant(subject: "ada lovelace", title: "Ada Lovelace"))
        XCTAssertTrue(KnowledgePanelService.isTitleRelevant(subject: "torproject", title: "The Tor Project"))
        XCTAssertFalse(KnowledgePanelService.isTitleRelevant(subject: "cool ai", title: "Artificial intelligence"))
        XCTAssertFalse(KnowledgePanelService.isTitleRelevant(subject: "fix a train", title: "xAI"))
    }

    func testSignificantTokensDropNoise() {
        XCTAssertEqual(KnowledgePanelService.significantTokens("The Tor Project"), ["tor", "project"])
        XCTAssertEqual(KnowledgePanelService.significantTokens("Apple Inc."), ["apple"])
        XCTAssertEqual(KnowledgePanelService.significantTokens("official site"), [])
    }

    // MARK: - Classifier no longer over-promotes plain words to entities

    func testClassifierKeepsKnownEntities() {
        XCTAssertEqual(KnowledgeQueryDetector.classify("xai"), .entity)
        XCTAssertEqual(KnowledgeQueryDetector.classify("elon musk"), .entity)
        XCTAssertEqual(KnowledgeQueryDetector.classify("who is ada lovelace"), .entity)
    }

    func testClassifierTreatsPlainWordsAsDictionary() {
        // Plain words with no exact catalog entry must not be promoted to brand/entity by a fuzzy
        // match ("site" used to fuzzy-match "the apple site", etc.).
        XCTAssertEqual(KnowledgeQueryDetector.classify("site"), .dictionary)
        XCTAssertEqual(KnowledgeQueryDetector.classify("happiness"), .dictionary)
    }

    // MARK: - Person kind comes from article facts, not query word-shape

    func testPersonKindRequiresBiographicalFacts() {
        // "apple pie" (a dessert) has no biographical facts → must NOT be tagged a person.
        XCTAssertFalse(KnowledgePanelService.articleDescribesPerson(facts: [
            KnowledgeFact(label: "Type", value: "Dessert"),
            KnowledgeFact(label: "Place of origin", value: "England")
        ]))
        // A real person's infobox carries birth/biographical fields.
        XCTAssertTrue(KnowledgePanelService.articleDescribesPerson(facts: [
            KnowledgeFact(label: "Born", value: "December 10, 1815"),
            KnowledgeFact(label: "Nationality", value: "British")
        ]))
    }

    // MARK: - Banner image normalization

    func testImageURLNormalization() {
        // Relative article asset → image CDN.
        XCTAssertEqual(
            GrokipediaArticleClient.normalizeImageURL("./_assets_/Ada_Lovelace_-_cropped.png")?.absoluteString,
            "https://assets.grokipedia.com/wiki/images/Ada_Lovelace_-_cropped.png"
        )
        // Real absolute CDN image is kept.
        XCTAssertEqual(
            GrokipediaArticleClient.normalizeImageURL("https://assets.grokipedia.com/wiki/images/4234bcccfdc3.jpg")?.absoluteString,
            "https://assets.grokipedia.com/wiki/images/4234bcccfdc3.jpg"
        )
        // Grokipedia site chrome (icon/logo) means "no article image" → nil → SearXNG fallback.
        XCTAssertNil(GrokipediaArticleClient.normalizeImageURL("https://grokipedia.com/icon-512x512.png"))
        XCTAssertNil(GrokipediaArticleClient.normalizeImageURL(""))
    }

    // MARK: - Article text cleanup

    func testTextCleanupStripsCitationsAndFixesPunctuation() {
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("a sweet filling of sugar , cinnamon , and nutmeg ."),
            "a sweet filling of sugar, cinnamon, and nutmeg."
        )
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("It embodies comfort food. [1]"),
            "It embodies comfort food."
        )
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("Founded in 2025 [12] by xAI [citation needed]."),
            "Founded in 2025 by xAI."
        )
    }

    func testTextCleanupStripsMarkdownAndWikiLinks() {
        // Markdown links → just their text.
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("[Elon Musk](/Elon_Musk) and 11 researchers"),
            "Elon Musk and 11 researchers"
        )
        // Wiki-style links with an anchor/pipe → the display text.
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("see [[#Establishment and Key Figures|Establishment and Key Figures]]"),
            "see Establishment and Key Figures"
        )
        XCTAssertEqual(
            GrokipediaArticleClient.cleanupSpacing("[Jared Birchall](/Jared_Birchall) (finance and legal)"),
            "Jared Birchall (finance and legal)"
        )
    }
}
