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

    /// Guards the one-time background preload so the home's onAppear and the hero slot can't launch it twice.
    private var preloadStarted = false
    /// True while a coalesced top-story recompute is pending (see `setTopStoryDirty`).
    private var topStoryRecomputeScheduled = false
    /// True while a manual/auto refresh is refetching all topics — drives the Refresh button's spinner.
    private(set) var isRefreshing = false

    /// How often the home news auto-refreshes while it's on screen (gentle: bounded + coalesced, and only
    /// while the news home is actually visible — the view's `.task` is cancelled the moment it disappears).
    static let autoRefreshInterval: TimeInterval = 12 * 60

    /// Max topic fetches in flight at once during the background preload. Loading all 10 in parallel spiked
    /// the local (same-machine) SearXNG and flooded the main thread with post-processing the instant the
    /// home opened; a small ceiling keeps it smooth while still filling the feed quickly.
    private static let preloadConcurrency = 3
    /// Delay before the background preload starts — lets the hero (logo + search) paint and its reveal
    /// animation run before any news CPU work lands on the main thread.
    private static let preloadStartDelay: Duration = .milliseconds(450)
    /// Backoff schedule for retrying topics that failed the initial preload (e.g. the local SearXNG was
    /// still starting up at launch). Each entry is how long to wait before the next retry of the topics
    /// still unresolved. Keeps the feed self-healing without the user needing to press Refresh.
    private static let preloadRetryBackoff: [Duration] = [.seconds(2), .seconds(4)]

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
        if topStoryRecomputeScheduled { return true }
        return Self.heroTopicIDs.contains { stories[$0] == nil || loading.contains($0) }
    }

    /// Cache lifetime — a home tab reuses topic news for 20 minutes instead of refetching each visit.
    static let ttl: TimeInterval = 20 * 60

    /// Whether the news home should render at all (off in Maximum Privacy or without an instance).
    static func isEnabled(instances: [SearXNGInstance]) -> Bool {
        PrivacyManager.shared.appPrivacyMode != .maximum && !instances.isEmpty
    }

    /// Fire-and-forget entry used by each topic section's `onAppear`, so a topic loads as the user scrolls
    /// it in. Cache-guarded and de-duped against in-flight loads, so it never double-fetches a topic the
    /// background `preload` is already handling.
    func loadIfNeeded(_ topic: Topic, instances: [SearXNGInstance]) {
        Task { @MainActor in await load(topic, instances: instances) }
    }

    /// Stories for `topicID` with cross-topic duplicates removed: any article already shown by a
    /// HIGHER-PRIORITY topic (earlier in `topics`) is dropped here, so the same story never appears twice
    /// as the user scrolls (a big story that legitimately runs under both "world" and "technology" shows
    /// once, under the higher topic). Deterministic — keyed on `topics` order, not async load order — so it
    /// stays stable across refreshes. Cheap: ~10 topics × ≤12 stories, and only near-identical URLs merge
    /// (in-topic near-duplicates are already collapsed by clustering).
    func dedupedStories(for topicID: String) -> [SearXNGResult] {
        guard let own = stories[topicID], !own.isEmpty else { return [] }
        var claimed = Set<String>()
        for topic in Self.topics {
            if topic.id == topicID { break }
            for story in stories[topic.id] ?? [] {
                claimed.insert(SearchResultProcessor.canonicalURLKey(story.url))
            }
        }
        return own.filter { claimed.insert(SearchResultProcessor.canonicalURLKey($0.url)).inserted }
    }

    /// Loads a single topic's news (awaitable, so the bounded `preload` can throttle concurrency). No-op in
    /// Maximum Privacy, when already fresh in cache, or when already loading.
    func load(_ topic: Topic, instances: [SearXNGInstance]) async {
        guard Self.isEnabled(instances: instances) else { return }
        guard !loading.contains(topic.id) else { return }
        if let ts = lastFetched[topic.id],
           Date().timeIntervalSince(ts) < Self.ttl,
           !(stories[topic.id]?.isEmpty ?? true) {
            return
        }
        loading.insert(topic.id)   // atomic: no suspension between the guard above and here

        let fetched = try? await SearXNGService.shared.searchWithFallback(
            query: topic.query,
            categories: "news",
            instances: instances,
            language: Localization.searchLanguageCode,
            options: SearchContentSafety.shared.searchOptions(pageNo: 1)
        )
        loading.remove(topic.id)
        guard let fetched else {
            // A failed fetch (the local SearXNG still warming up right after launch, or a transient network
            // error) must NOT poison the topic into a permanent empty/collapsed state. That was the "home
            // news never appears until you press Refresh" regression: `preload` fetches every topic ~450ms
            // after the home paints — before SearXNG is ready at cold start — the cold fetches fail, each
            // was written resolved-empty (`[]`), and a resolved-empty topic's section collapses, which
            // removes the very `.onAppear` that would retry it on scroll. Leave it unresolved (nil, and no
            // freshness stamp) so the section keeps its retryable placeholder and refetches on the next
            // scroll-in / auto-refresh / preload self-heal.
            setTopStoryDirty()
            return
        }
        lastFetched[topic.id] = Date()   // stamp freshness only on a successful fetch
        let processed = SearchResultProcessor.process(
            raw: fetched.results, query: topic.query, category: "news", append: false
        )
        // Live + sharp: keep only recent stories with a real, upscalable photo (drops reuters' 80px logos
        // and stale relevance-matched archive articles), newest first. The publish date is parsed ONCE per
        // item (decorate-sort) — the old `.sorted { $0.newsPublishedDate ... }` re-parsed every date on
        // every comparison (5 DateFormatters + regex each), turning the sort into O(n log n) date parsing
        // on the main thread for each of ~10 topics.
        let dated = processed
            .filter { $0.newsHasResizablePhoto && $0.isRecentNews }
            .map { (result: $0, date: $0.newsPublishedDate ?? .distantPast) }
            .sorted { $0.date > $1.date }
        // Cluster only the freshest handful: we keep 12 leads and the O(n²) clustering doesn't need the tail.
        let base = dated.prefix(24).map(\.result)
        let leads = NewsClustering.cluster(base, query: topic.query).map(\.lead)
        stories[topic.id] = Array(leads.prefix(12))
        setTopStoryDirty()
    }

    /// Marks the hero's top-story pick stale and schedules a SINGLE recompute shortly after. A burst of
    /// topic loads (the bounded preload finishing several close together) collapses into one clustering
    /// pass instead of re-running the whole cross-topic O(n²) cluster after every single topic — which is
    /// what it used to do (up to 10× on the main thread as topics streamed in).
    private func setTopStoryDirty() {
        guard !topStoryRecomputeScheduled else { return }
        topStoryRecomputeScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            topStoryRecomputeScheduled = false
            recomputeTopStory()
        }
    }

    /// Recomputes the hero from the hard-news topic feeds: pools their (already fresh, real-photo,
    /// newest-first) stories, drops roundup/soft-news filler, clusters across topics, and picks the
    /// standout by coverage → freshness → breaking. A big story runs in several topics → a bigger
    /// cross-topic cluster → wins. Coalesced via `setTopStoryDirty` so it runs once per burst, not per topic.
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

    /// Preloads the topic feeds so scrolling reveals ready content — WITHOUT the old "fire all 10 at once"
    /// stampede that spiked the local SearXNG and flooded the main thread the instant the home opened.
    /// Runs once (guarded), deferred past the first paint, hard-news (hero) topics first, and capped to a
    /// few fetches in flight at a time. Each `load` is cache-guarded, so repeat home visits within the TTL
    /// are free and this never double-fetches a topic a scrolled-in section already requested.
    func preload(instances: [SearXNGInstance]) {
        guard Self.isEnabled(instances: instances) else { return }
        guard !preloadStarted else { return }
        preloadStarted = true

        let ordered = orderedTopics
        Task { @MainActor in
            // Let the hero (logo + search) paint and its reveal animation run before news work begins.
            try? await Task.sleep(for: Self.preloadStartDelay)
            await runBoundedLoad(ordered, instances: instances)

            // Cold-start self-heal: if the local SearXNG wasn't ready when the first pass ran, those topics
            // failed and were left unresolved (see `load`). Retry just those a couple of times with a short
            // backoff so the feed fills on its own — no manual Refresh needed. `load` is cache-guarded, so
            // topics that already succeeded are skipped and nothing is double-fetched.
            for delay in Self.preloadRetryBackoff {
                let pending = ordered.filter { stories[$0.id] == nil }
                guard !pending.isEmpty, Self.isEnabled(instances: instances) else { break }
                try? await Task.sleep(for: delay)
                await runBoundedLoad(pending, instances: instances)
            }
        }
    }

    /// Forces a fresh reload of every topic — the manual Refresh button and the periodic auto-refresh both
    /// call this. Bypasses the per-topic TTL but reuses the same bounded/coalesced machinery, so it never
    /// stampedes. Existing cards stay visible until each topic's new results replace them (no blank flash).
    func refresh(instances: [SearXNGInstance]) {
        guard Self.isEnabled(instances: instances) else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastFetched.removeAll()   // invalidate freshness so `load` refetches instead of TTL-skipping
        let ordered = orderedTopics
        Task { @MainActor in
            await runBoundedLoad(ordered, instances: instances)
            isRefreshing = false
        }
    }

    /// Hero (hard-news) topics first — they drive the top-story banner — then the rest, in declared order.
    private var orderedTopics: [Topic] {
        Self.heroTopicIDs.compactMap { id in Self.topics.first { $0.id == id } }
            + Self.topics.filter { !Self.heroTopicIDs.contains($0.id) }
    }

    /// Runs `load` across `topics` with at most `preloadConcurrency` fetches in flight at once (bounded
    /// task group), so neither the local SearXNG nor the main thread is hit with all 10 topics at once.
    private func runBoundedLoad(_ topics: [Topic], instances: [SearXNGInstance]) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < topics.count else { return }
                let topic = topics[next]
                next += 1
                group.addTask { await self.load(topic, instances: instances) }
            }
            for _ in 0..<min(Self.preloadConcurrency, topics.count) { addNext() }
            while await group.next() != nil { addNext() }
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
        preloadStarted = false
        topStoryRecomputeScheduled = false
        isRefreshing = false
    }
}
