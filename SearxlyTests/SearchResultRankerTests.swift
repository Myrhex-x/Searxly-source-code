//
//  SearchResultRankerTests.swift
//  SearxlyTests
//
//  Guards the native SERP re-ranker against the two reported relevance failures:
//   1. A person's name surfacing an unrelated host that merely shares one word
//      ("elon musk" → "elon.edu", a university).
//   2. A brand/company query failing to surface that company's own website
//      ("openai" → openai.com buried under aggregator/discussion pages).
//
//  Both are pinned here so they can't silently regress: entity-host anchoring and
//  query-word coverage scoring are the mechanisms under test.
//

import XCTest
@testable import Searxly

final class SearchResultRankerTests: XCTestCase {

    // Builds results via JSON decode — SearXNGResult has ~16 fields and only title/url are required,
    // so decoding minimal objects is far cleaner than the memberwise initializer.
    private func makeResults(_ items: [(title: String, url: String, content: String)]) -> [SearXNGResult] {
        let objects: [[String: String]] = items.map {
            ["title": $0.title, "url": $0.url, "content": $0.content]
        }
        let data = try! JSONSerialization.data(withJSONObject: objects)
        return try! JSONDecoder().decode([SearXNGResult].self, from: data)
    }

    private func ranked(_ items: [(title: String, url: String, content: String)],
                        query: String,
                        category: String? = nil) -> [SearXNGResult] {
        SearchResultRanker.reranked(makeResults(items), query: query, category: category)
    }

    // MARK: - Person name: partial-word match must not win

    func testElonMuskDoesNotSurfaceElonUniversity() {
        let results = ranked([
            ("Elon University",
             "https://www.elon.edu",
             "Elon University is a private university in Elon, North Carolina."),
            ("Elon Musk — Biography",
             "https://www.biography.com/business/elon-musk",
             "Elon Musk is a businessman known for Tesla, SpaceX and X."),
        ], query: "elon musk")

        // The university covers only "elon"; the bio covers both "elon" and "musk".
        XCTAssertNotEqual(results.first?.url, "https://www.elon.edu",
                          "A single-word match (elon.edu) must not rank first for 'elon musk'.")
        XCTAssertEqual(results.first?.url, "https://www.biography.com/business/elon-musk")
    }

    func testFullCoverageOutranksPartialCoverageGenerally() {
        // No curated entity involved here — pure coverage scoring.
        let results = ranked([
            ("Paris Hotels", "https://example-hotels.com/paris",
             "Book hotels in paris with great deals."),
            ("Paris Hilton Official", "https://example-fans.com/paris-hilton",
             "Paris Hilton news, music and media for paris hilton fans."),
        ], query: "paris hilton")

        XCTAssertEqual(results.first?.url, "https://example-fans.com/paris-hilton")
    }

    // MARK: - Brand / company: official site must surface

    func testCompanyOfficialSiteBeatsAggregator() {
        let results = ranked([
            ("OpenAI subreddit", "https://www.reddit.com/r/openai",
             "openai discussion, openai news, openai models, all things openai"),
            ("OpenAI", "https://openai.com",
             "OpenAI is an AI research and deployment company."),
        ], query: "openai")

        XCTAssertEqual(results.first?.url, "https://openai.com",
                       "A curated brand query must anchor its own official host above aggregators.")
    }

    func testSingleWordBrandRanksOfficialHostFirst() {
        let results = ranked([
            ("Tesla, Inc. — Wikipedia", "https://en.wikipedia.org/wiki/Tesla,_Inc.",
             "Tesla, Inc. is an American multinational automotive company."),
            ("Tesla news on Teslarati", "https://www.teslarati.com/category/tesla",
             "The latest Tesla news and rumors."),
            ("Tesla", "https://www.tesla.com",
             "Electric cars, solar and clean energy."),
        ], query: "tesla")

        XCTAssertEqual(results.first?.url, "https://www.tesla.com")
    }

    func testPersonEntityAnchorsOfficialDestination() {
        // "elon musk" resolves to a curated person whose official destination is x.com — neither word
        // appears in that host, so this only works because of entity anchoring (not token matching).
        let results = ranked([
            ("Random blog about Musk", "https://some-blog.example/elon-musk-thoughts",
             "Some opinions about elon musk and his companies."),
            ("Elon Musk on X", "https://x.com/elonmusk",
             "Elon Musk's official X account."),
        ], query: "elon musk")

        XCTAssertEqual(results.first?.url, "https://x.com/elonmusk")
    }

    // MARK: - No-regression sanity

    func testNonEntityQueryPreservesAllResults() {
        let input: [(title: String, url: String, content: String)] = [
            ("How to bake sourdough", "https://example.com/sourdough",
             "A guide to baking sourdough bread at home."),
            ("Sourdough starter tips", "https://example.org/starter",
             "Tips for maintaining a healthy sourdough starter."),
        ]
        let results = ranked(input, query: "how to bake sourdough bread")
        XCTAssertEqual(Set(results.map(\.url)), Set(input.map(\.url)),
                       "Re-ranking must reorder, never drop or duplicate results.")
    }

    func testEmptyAndSingleResultAreStable() {
        XCTAssertTrue(SearchResultRanker.reranked([], query: "anything", category: nil).isEmpty)
        let one = ranked([("Only", "https://only.example", "single result")], query: "only")
        XCTAssertEqual(one.count, 1)
    }

    // MARK: - Regression table: query → expected top host
    //
    // Each case is a realistic SERP (aggregators, news, blogs competing with the right answer)
    // pinned to the host that must come out on top. Add a row here whenever a ranking bug is
    // fixed so it can't silently regress.

    private func assertTopHost(_ expectedHost: String,
                               query: String,
                               category: String? = nil,
                               results items: [(title: String, url: String, content: String)],
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let output = ranked(items, query: query, category: category)
        let topHost = output.first.flatMap { URL(string: $0.url)?.host?.lowercased() }?
            .replacingOccurrences(of: "www.", with: "")
        XCTAssertEqual(topHost, expectedHost,
                       "'\(query)' must surface \(expectedHost) first (got \(output.first?.url ?? "nothing"))",
                       file: file, line: line)
        XCTAssertEqual(Set(output.map(\.url)), Set(items.map(\.url)),
                       "Re-ranking for '\(query)' must reorder, never drop or duplicate results.",
                       file: file, line: line)
    }

    func testBrandQueriesBeatAggregators() {
        assertTopHost("roblox.com", query: "roblox", results: [
            ("ROBLOX FUNNY MOMENTS #42", "https://www.youtube.com/watch?v=abc123",
             "roblox gameplay video, roblox funny moments compilation"),
            ("r/roblox", "https://www.reddit.com/r/roblox",
             "The community-run subreddit for roblox players."),
            ("Roblox", "https://www.roblox.com",
             "Roblox is an immersive platform for communication and connection."),
        ])

        assertTopHost("spotify.com", query: "spotify", results: [
            ("r/spotify", "https://www.reddit.com/r/spotify",
             "Discussion about spotify features and playlists."),
            ("Spotify launches new feature", "https://techcrunch.com/2026/05/01/spotify-new-feature",
             "spotify announced a new feature for premium subscribers today."),
            ("Spotify", "https://www.spotify.com",
             "Listen to music and podcasts on spotify."),
        ])

        assertTopHost("minecraft.net", query: "minecraft", results: [
            ("Minecraft — full playthrough", "https://www.youtube.com/watch?v=xyz789",
             "minecraft survival lets play episode one"),
            ("Minecraft Wiki", "https://minecraft.fandom.com/wiki/Minecraft",
             "The minecraft wiki with guides and crafting recipes."),
            ("Welcome to the Minecraft Official Site", "https://www.minecraft.net",
             "Explore new gaming adventures with minecraft."),
        ])

        assertTopHost("netflix.com", query: "netflix", results: [
            ("Netflix raises prices again", "https://www.theverge.com/2026/netflix-price-increase",
             "netflix announced another price increase for subscribers."),
            ("r/netflix", "https://www.reddit.com/r/netflix",
             "netflix shows discussion and recommendations."),
            ("Netflix — Watch TV Shows Online", "https://www.netflix.com",
             "Watch netflix movies and TV shows online."),
        ])
    }

    func testCuratedEntityQueriesAnchorOfficialHosts() {
        // spacex is a curated company entity — its own site must beat news coverage.
        assertTopHost("spacex.com", query: "spacex", results: [
            ("SpaceX launches 40th mission this year", "https://www.cnbc.com/2026/06/spacex-launch",
             "spacex completed another starlink launch on tuesday."),
            ("SpaceX Starship live stream", "https://www.youtube.com/watch?v=starship",
             "Watch the spacex starship flight test live."),
            ("SpaceX", "https://www.spacex.com",
             "SpaceX designs, manufactures and launches advanced rockets and spacecraft."),
        ])

        // Person entities anchor a host that contains NEITHER query word — pure entity anchoring.
        assertTopHost("openai.com", query: "sam altman", results: [
            ("Sam Altman fan page", "https://samaltman-fans.example.com",
             "Everything about sam altman, sam altman quotes and sam altman news."),
            ("OpenAI", "https://openai.com",
             "OpenAI is an AI research and deployment company led by its CEO."),
        ])

        assertTopHost("microsoft.com", query: "satya nadella", results: [
            ("Satya Nadella — LinkedIn", "https://www.linkedin.com/in/satyanadella",
             "Satya Nadella, Chairman and CEO at Microsoft."),
            ("Microsoft", "https://www.microsoft.com",
             "Microsoft corporate site."),
        ])

        // The "elon musk → elon.edu" class of bug, applied to another person: a host covering
        // only ONE word of the name must not beat the anchored destination.
        assertTopHost("taylorswift.com", query: "taylor swift", results: [
            ("Swift River Rafting", "https://www.swiftrafting.example.com",
             "Guided swift water rafting trips for the whole family."),
            ("Taylor Swift — Official Site", "https://www.taylorswift.com",
             "The official site of taylor swift."),
        ])
    }

    func testExactDomainQueryBeatsUnrelatedBigBrands() {
        // Locks the "torproject → x.com" bug: hard-coded big-brand hosts must not float to the
        // top of navigational queries that aren't about them.
        assertTopHost("torproject.org", query: "torproject", results: [
            ("Tor Project on X", "https://x.com/torproject",
             "Official X account of the torproject."),
            ("Tesla", "https://www.tesla.com",
             "Electric cars, solar and clean energy."),
            ("The Tor Project", "https://www.torproject.org",
             "Defend yourself against tracking and surveillance with the torproject browser."),
        ])
    }

    func testInformationalQueryFavorsFullCoverageAnswer() {
        // "how to" → informational: the page answering the whole question must beat the
        // official-looking root domain that only matches one word.
        assertTopHost("stackoverflow.com", query: "how to fix python requests timeout", results: [
            ("Python", "https://www.python.org",
             "The official home of the python programming language."),
            ("How to fix python requests timeout errors", "https://stackoverflow.com/questions/12345/requests-timeout",
             "You can fix python requests timeout errors by passing the timeout parameter."),
        ])
    }

    func testGrokipediaOutranksBlogsForEncyclopedicQueries() {
        assertTopHost("grokipedia.com", query: "quantum computing", results: [
            ("Quantum computing explained", "https://example-tech-blog.com/articles/2026/quantum",
             "A long introduction to quantum computing for beginners."),
            ("Quantum computing", "https://grokipedia.com/page/Quantum_computing",
             "Quantum computing is a type of computation using quantum-mechanical phenomena."),
        ])
    }

    func testWikipediaIsPenalizedForNonWikiQueries() {
        assertTopHost("example-quantum.com", query: "quantum computing", results: [
            ("Quantum computing — Wikipedia", "https://en.wikipedia.org/wiki/Quantum_computing",
             "Quantum computing is a type of computation whose operations exploit quantum mechanics."),
            ("Quantum computing", "https://www.example-quantum.com",
             "Learn quantum computing concepts, algorithms and hardware."),
        ])
    }

    // MARK: - Intent detection

    func testDetectIntentInformational() {
        let q = "how to bake bread"
        XCTAssertEqual(SearchResultRanker.detectIntent(q, tokens: ["how", "to", "bake", "bread"]), .informational)
    }

    func testDetectIntentNavigationalShortBrand() {
        XCTAssertEqual(SearchResultRanker.detectIntent("tesla", tokens: ["tesla"]), .navigational)
    }

    func testDetectIntentGeneralLongQuery() {
        let q = "cheap flights from paris to tokyo in september"
        let tokens = Set(q.split(separator: " ").map(String.init))
        XCTAssertEqual(SearchResultRanker.detectIntent(q, tokens: tokens), .general)
    }

    // MARK: - SERP source policy (Grokipedia-first / Wikipedia-suppressed)

    func testWikipediaSuppressedUnlessExplicitlyRequested() {
        let results = makeResults([
            ("Quantum computing — Wikipedia", "https://en.wikipedia.org/wiki/Quantum_computing", "wiki article"),
            ("Quantum computing basics", "https://example.com/quantum", "an article about quantum computing"),
        ])

        let suppressed = SERPSourcePolicy.applyAll(results, query: "quantum computing")
        XCTAssertFalse(suppressed.contains { $0.url.contains("wikipedia.org") },
                       "Wikipedia must be hidden from the SERP for non-wiki queries.")

        let kept = SERPSourcePolicy.applyAll(results, query: "quantum computing wikipedia")
        XCTAssertTrue(kept.contains { $0.url.contains("wikipedia.org") },
                      "Explicitly asking for Wikipedia must keep it in the SERP.")
    }

    func testExplicitWikipediaQueryDetection() {
        XCTAssertTrue(SERPSourcePolicy.isExplicitWikipediaQuery("wikipedia"))
        XCTAssertTrue(SERPSourcePolicy.isExplicitWikipediaQuery("quantum computing wikipedia"))
        XCTAssertTrue(SERPSourcePolicy.isExplicitWikipediaQuery("site:wikipedia.org tor"))
        XCTAssertFalse(SERPSourcePolicy.isExplicitWikipediaQuery("quantum computing"))
        XCTAssertFalse(SERPSourcePolicy.isExplicitWikipediaQuery("tesla"))
    }

    func testApplyAllPutsBestGrokipediaFirst() {
        let results = makeResults([
            ("Random blog", "https://example.com/blog", "unrelated content"),
            ("Nikola Tesla", "https://grokipedia.com/page/Nikola_Tesla", "the inventor"),
            ("Tesla, Inc.", "https://grokipedia.com/page/Tesla,_Inc.", "the company"),
        ])
        let output = SERPSourcePolicy.applyAll(results, query: "nikola tesla")
        XCTAssertEqual(output.first?.url, "https://grokipedia.com/page/Nikola_Tesla",
                       "The Grokipedia page matching the subject must be promoted to the top.")
        XCTAssertEqual(output.count, results.count)
    }
}
