//
//  HomeNewsFeed.swift
//  Searxly
//
//  Backs the "browse news by topic" section on the home page. Lazily fetches a handful of news topics
//  (Technology, World, …) through the same privacy-gated SearXNGService, caches them in memory only
//  (never on disk), and is fully suppressed in Maximum Privacy. Loaded per-topic as the user scrolls
//  into it — a blank new tab makes no news requests until you actually go looking for news.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class HomeNewsFeed {
    static let shared = HomeNewsFeed()
    private init() {}

    struct Topic: Identifiable, Hashable {
        let id: String
        /// Localization key for the display name.
        let labelKey: String
        /// The news query run for this topic (and for "See all").
        let query: String
        let systemIcon: String
    }

    static let topics: [Topic] = [
        Topic(id: "world",         labelKey: "home_topic_world",         query: "world news",    systemIcon: "globe"),
        Topic(id: "war",           labelKey: "home_topic_war",           query: "war conflict",  systemIcon: "shield.lefthalf.filled"),
        Topic(id: "politics",      labelKey: "home_topic_politics",      query: "politics",      systemIcon: "megaphone"),
        Topic(id: "justice",       labelKey: "home_topic_justice",       query: "justice court", systemIcon: "building.columns"),
        Topic(id: "business",      labelKey: "home_topic_business",      query: "business",      systemIcon: "chart.line.uptrend.xyaxis"),
        Topic(id: "technology",    labelKey: "home_topic_technology",    query: "technology",    systemIcon: "cpu"),
        Topic(id: "science",       labelKey: "home_topic_science",       query: "science",       systemIcon: "atom"),
        Topic(id: "health",        labelKey: "home_topic_health",        query: "health",        systemIcon: "heart.text.square"),
        Topic(id: "sports",        labelKey: "home_topic_sports",        query: "sports",        systemIcon: "sportscourt"),
        Topic(id: "entertainment", labelKey: "home_topic_entertainment", query: "entertainment", systemIcon: "film")
    ]

    /// Distinct top stories per topic id (already clustered so no near-duplicate cards).
    private(set) var stories: [String: [SearXNGResult]] = [:]
    private(set) var loading: Set<String> = []
    private var lastFetched: [String: Date] = [:]

    /// The single most important story right now — derived from the HARD-NEWS topic feeds (below),
    /// recomputed whenever a topic loads. No dedicated fetch (generic "top news" queries are sports-
    /// polluted); this reuses the topic data and never sources from Sports/Entertainment.
    private(set) var topStory: NewsCluster?

    /// Topics the hero may draw from — hard news only (Sports/Entertainment excluded so a match report
    /// never becomes "the top story").
    private static let heroTopicIDs = ["world", "war", "politics", "business", "justice", "technology", "science", "health"]

    /// True while the hero is still resolving (its source topics haven't all loaded and there's no pick yet).
    var topStoryLoading: Bool {
        if topStory != nil { return false }
        return Self.heroTopicIDs.contains { stories[$0] == nil || loading.contains($0) }
    }

    /// Cache lifetime — a home tab reuses topic news for 20 minutes instead of refetching each visit.
    static let ttl: TimeInterval = 20 * 60

    /// Whether the news home should render at all (off in Maximum Privacy or without an instance).
    static func isEnabled(instances: [SearXNGInstance]) -> Bool {
        PrivacyManager.shared.appPrivacyMode != .maximum && !instances.isEmpty
    }

    /// Fetches a topic's news if it isn't cached/fresh and isn't already loading. No-op in Maximum
    /// Privacy. Called from each topic section's onAppear, so it only fires as the user scrolls in.
    func loadIfNeeded(_ topic: Topic, instances: [SearXNGInstance]) {
        guard Self.isEnabled(instances: instances) else { return }
        guard !loading.contains(topic.id) else { return }
        if let ts = lastFetched[topic.id],
           Date().timeIntervalSince(ts) < Self.ttl,
           !(stories[topic.id]?.isEmpty ?? true) {
            return
        }
        loading.insert(topic.id)
        Task { @MainActor in
            let fetched = try? await SearXNGService.shared.searchWithFallback(
                query: topic.query,
                categories: "news",
                instances: instances,
                language: Localization.searchLanguageCode,
                options: SearchContentSafety.shared.searchOptions(pageNo: 1)
            )
            loading.remove(topic.id)
            lastFetched[topic.id] = Date()
            guard let fetched else {
                // Mark resolved-empty so the section collapses (and doesn't retry until the TTL lapses).
                stories[topic.id] = stories[topic.id] ?? []
                recomputeTopStory()
                return
            }
            let processed = SearchResultProcessor.process(
                raw: fetched.results, query: topic.query, category: "news", append: false
            )
            // Live + sharp: keep only recent stories with a real, upscalable photo (drops reuters' 80px
            // logos and stale relevance-matched archive articles), newest first, then cluster to distinct.
            let base = processed
                .filter { $0.newsHasResizablePhoto && $0.isRecentNews }
                .sorted { ($0.newsPublishedDate ?? .distantPast) > ($1.newsPublishedDate ?? .distantPast) }
            let leads = NewsClustering.cluster(base, query: topic.query).map(\.lead)
            stories[topic.id] = Array(leads.prefix(12))
            recomputeTopStory()
        }
    }

    /// Recomputes the hero from the hard-news topic feeds: pools their (already fresh, real-photo,
    /// newest-first) stories, drops roundup/soft-news filler, clusters across topics, and picks the
    /// standout by coverage → freshness → breaking. A big story runs in several topics → a bigger
    /// cross-topic cluster → wins. Cheap (runs only when a topic loads, not per render).
    private func recomputeTopStory() {
        let pool = Self.heroTopicIDs
            .flatMap { stories[$0] ?? [] }
            .filter { !Self.isRoundup($0.title) && !Self.looksLikeSoftNews($0.title) }
        guard !pool.isEmpty else { return }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert(SearchResultProcessor.canonicalURLKey($0.url)).inserted }
        let clusters = NewsClustering.cluster(unique, query: "top story")
        topStory = clusters.enumerated().max {
            Self.topStoryScore($0.element, index: $0.offset) < Self.topStoryScore($1.element, index: $1.offset)
        }?.element
    }

    private static func topStoryScore(_ cluster: NewsCluster, index: Int) -> Int {
        let lead = cluster.lead
        var s = 0
        if lead.isBreakingNews { s += 400 }
        switch lead.newsFreshness {
        case .live: s += 250
        case .today: s += 140
        case .recent: s += 30
        case .older, .unknown: s += 0
        }
        // Coverage is the strongest "importance" signal — a story many outlets/topics run beats a one-off.
        s += cluster.sourceCount * 90
        s -= index * 2
        return s
    }

    /// Sports / celebrity / entertainment markers — fine in their own topic rows, but not "the top story".
    private static func looksLikeSoftNews(_ title: String) -> Bool {
        let t = title.lowercased()
        let markers = [
            "world cup", " vs ", " vs.", "match", "goal", "playoff", "playoffs", "nba", "nfl", "mlb",
            "nhl", " fc ", "premier league", "la liga", "champions league", "tournament", "final score",
            "top plays", "highlights", "standings", "fixtures", "transfer rumor", "transfer news",
            "transfer talk", "loan ", "skating", "hockey", "touchdown", "home run", "golf", "olympic",
            "medal", "box office", "trailer", "celebrity", "kardashian", "red carpet", "grammys",
            "oscars", "album", "concert", "movie review", "tv review", "recap", "power ranking"
        ]
        return markers.contains { t.contains($0) }
    }

    /// Eagerly resolves every topic up front (the user wants the news home ready without scrolling); the
    /// hero derives from them. Each call is cache-guarded, so repeat home visits within the TTL are free.
    func loadAll(instances: [SearXNGInstance]) {
        guard Self.isEnabled(instances: instances) else { return }
        for topic in Self.topics {
            loadIfNeeded(topic, instances: instances)
        }
    }

    /// Titles that are digests / listicles / opinion, not a single breaking story — excluded from the hero.
    private static func isRoundup(_ title: String) -> Bool {
        let t = title.lowercased()
        let markers = [
            "top news", "news summary", "news bulletin", "latest news", "roundup", "briefing",
            "what to know", "in pictures", "in photos", "recap", "digest", "poll news",
            "news stories", "pulitzer", "live updates", "liveblog", "as it happened", "newsletter",
            "quiz", "crossword", "horoscope", "podcast", "watch:", "video:", "photos:", "opinion",
            "editorial", "cartoon", "how to watch", "day in photos"
        ]
        return markers.contains { t.contains($0) }
    }

    /// Drops everything from memory (entering Maximum Privacy, panic wipe, etc.).
    func clear() {
        stories = [:]
        loading = []
        lastFetched = [:]
        topStory = nil
    }
}
