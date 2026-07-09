//
//  HomeNewsFeed.swift
//  SearxlyiOS
//
//  Backs the "scroll down for news" topic feed on the start page. Lazily fetches a handful of news
//  topics (World, Technology, …) through the configured SearXNG instance, caches them in memory only
//  (never on disk), and never runs in private tabs or when the feed is switched off. Topics load as the
//  user scrolls into them — the hero paints instantly and a blank tab makes no news requests until you
//  actually go looking. This is the iOS twin of the macOS HomeNewsFeed, built on the shared recency +
//  clustering engine (SearXNGModels / NewsClustering / SearchResultProcessor).
//

import Foundation
import Observation

@MainActor
@Observable
final class HomeNewsFeed {
    static let shared = HomeNewsFeed()
    private init() {}

    struct Topic: Identifiable, Hashable {
        let id: String
        /// English display label (localized at render via `L()`).
        let label: String
        /// The news query run for this topic (and for "See all").
        let query: String
        let systemIcon: String
    }

    static let topics: [Topic] = [
        Topic(id: "world",         label: "World",         query: "world news",    systemIcon: "globe"),
        Topic(id: "war",           label: "Conflict",      query: "war conflict",  systemIcon: "shield.lefthalf.filled"),
        Topic(id: "politics",      label: "Politics",      query: "politics",      systemIcon: "megaphone"),
        Topic(id: "business",      label: "Business",      query: "business",      systemIcon: "chart.line.uptrend.xyaxis"),
        Topic(id: "technology",    label: "Technology",    query: "technology",    systemIcon: "cpu"),
        Topic(id: "science",       label: "Science",       query: "science",       systemIcon: "atom"),
        Topic(id: "health",        label: "Health",        query: "health",        systemIcon: "heart.text.square"),
        Topic(id: "sports",        label: "Sports",        query: "sports",        systemIcon: "sportscourt"),
        Topic(id: "entertainment", label: "Entertainment", query: "entertainment", systemIcon: "film")
    ]

    /// Distinct top stories per topic id (already clustered so no near-duplicate cards).
    private(set) var stories: [String: [SearXNGResult]] = [:]
    private(set) var loading: Set<String> = []
    private var lastFetched: [String: Date] = [:]

    /// Guards the one-time background preload so the home's onAppear and the hero slot can't launch it twice.
    private var preloadStarted = false
    /// True while a coalesced top-story recompute is pending (see `setTopStoryDirty`).
    private var topStoryRecomputeScheduled = false
    /// True while a manual/auto refresh is refetching all topics — drives the Refresh control's spinner.
    private(set) var isRefreshing = false

    /// The single most important story right now — derived from the HARD-NEWS topic feeds, recomputed
    /// whenever a topic loads. No dedicated fetch (generic "top news" queries are sports-polluted); this
    /// reuses the topic data and never sources from Sports/Entertainment.
    private(set) var topStory: NewsCluster?

    /// Topics the hero may draw from — hard news only (Sports/Entertainment excluded so a match report
    /// never becomes "the top story").
    private static let heroTopicIDs = ["world", "war", "politics", "business", "technology", "science", "health"]

    /// How often the feed auto-refreshes while the home is on screen (gentle + coalesced; the view's
    /// `.task` is cancelled the moment the home disappears).
    static let autoRefreshInterval: TimeInterval = 12 * 60
    /// A home tab reuses topic news for 20 minutes instead of refetching each visit.
    static let ttl: TimeInterval = 20 * 60

    /// Max topic fetches in flight at once during the background preload — a small ceiling keeps the
    /// main thread smooth (post-processing each topic is real work) while still filling the feed quickly.
    private static let preloadConcurrency = 3
    /// Delay before the preload starts — lets the hero (logo + glow) paint and settle first.
    private static let preloadStartDelay: Duration = .milliseconds(450)

    /// Whether the feed should render/fetch at all (respects the setting; instances always exist).
    var isEnabled: Bool {
        ShieldSettings.shared.newsHomeFeed && !SearchSettings.shared.searchInstances.isEmpty
    }

    /// Topics the user hasn't hidden (Settings ▸ Search ▸ News ▸ Topics), in declared order.
    var visibleTopics: [Topic] {
        Self.topics.filter { ShieldSettings.shared.isNewsTopicVisible($0.id) }
    }

    /// True while the hero is still resolving (its source topics haven't all loaded and there's no pick yet).
    var topStoryLoading: Bool {
        if topStory != nil { return false }
        if topStoryRecomputeScheduled { return true }
        return visibleHeroTopicIDs.contains { stories[$0] == nil || loading.contains($0) }
    }

    /// Hard-news hero topics the user hasn't hidden — the hero only draws from these.
    private var visibleHeroTopicIDs: [String] {
        Self.heroTopicIDs.filter { ShieldSettings.shared.isNewsTopicVisible($0) }
    }

    // MARK: - Loading

    /// Fire-and-forget entry used by each topic section's `onAppear`. Cache-guarded and de-duped
    /// against in-flight loads, so it never double-fetches a topic the preload is already handling.
    func loadIfNeeded(_ topic: Topic) {
        Task { @MainActor in await load(topic) }
    }

    /// Stories for `topicID` with cross-topic duplicates removed: any article already shown by a
    /// HIGHER-PRIORITY topic (earlier in `topics`) is dropped here, so the same story never appears
    /// twice as the user scrolls. Deterministic (keyed on `topics` order, not async load order).
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

    /// Loads a single topic's news (awaitable, so the bounded preload can throttle concurrency).
    /// No-op when the feed is off, already fresh in cache, or already loading.
    func load(_ topic: Topic) async {
        guard isEnabled else { return }
        guard !loading.contains(topic.id) else { return }
        if let ts = lastFetched[topic.id],
           Date().timeIntervalSince(ts) < Self.ttl,
           !(stories[topic.id]?.isEmpty ?? true) {
            return
        }
        loading.insert(topic.id)   // atomic: no suspension between the guard above and here

        let fetched = await fetchNews(query: topic.query)
        loading.remove(topic.id)
        lastFetched[topic.id] = Date()
        guard let fetched, !fetched.isEmpty else {
            // Mark resolved-empty so the section collapses (and doesn't retry until the TTL lapses).
            stories[topic.id] = stories[topic.id] ?? []
            setTopStoryDirty()
            return
        }
        // Same post-fetch pipeline as everywhere else (dedup, SafeSearch, re-rank, news-date priming).
        let processed = SearchResultProcessor.process(
            raw: fetched, query: topic.query, category: "news", append: false
        )
        stories[topic.id] = Array(Self.freshLeads(from: processed, query: topic.query).prefix(12))
        setTopStoryDirty()
    }

    /// Recency-first leads for a topic: recent-dated stories newest-first, backfilled with the
    /// remaining ranked results so the feed still populates when an instance's news engines return
    /// few machine dates. Clustered so near-duplicate coverage collapses to one lead.
    private static func freshLeads(from processed: [SearXNGResult], query: String) -> [SearXNGResult] {
        let dated = processed
            .filter { $0.isRecentNews }
            .map { (result: $0, date: $0.newsPublishedDate ?? .distantPast) }
            .sorted { $0.date > $1.date }
            .map(\.result)

        var base = dated
        if base.count < 4 {
            var seen = Set(base.map { SearchResultProcessor.canonicalURLKey($0.url) })
            let extra = processed.filter { seen.insert(SearchResultProcessor.canonicalURLKey($0.url)).inserted }
            base = dated + extra
        }
        return NewsClustering.cluster(Array(base.prefix(24)), query: query).map(\.lead)
    }

    /// Rotates the configured instances (primary first, then JSON-API backups) until one serves news.
    private func fetchNews(query: String) async -> [SearXNGResult]? {
        let s = SearchSettings.shared
        for instance in s.searchInstances {
            if let results = try? await SearxngClient().search(
                query, base: instance, categories: "news",
                safeSearch: s.safeSearch.rawValue, language: s.language, pageNo: 1
            ), !results.isEmpty {
                return results
            }
        }
        return nil
    }

    // MARK: - Top story (hero)

    /// Marks the hero's pick stale and schedules a SINGLE recompute shortly after, so a burst of topic
    /// loads finishing close together collapses into one cross-topic clustering pass instead of N.
    private func setTopStoryDirty() {
        guard !topStoryRecomputeScheduled else { return }
        topStoryRecomputeScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            topStoryRecomputeScheduled = false
            recomputeTopStory()
        }
    }

    /// Pools the hard-news feeds, drops roundup/soft-news filler, clusters across topics, and picks the
    /// standout by coverage → freshness → breaking. A big story runs in several topics → a bigger
    /// cross-topic cluster → wins.
    private func recomputeTopStory() {
        let pool = visibleHeroTopicIDs
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
        // Nudge stories with a real, upscalable photo up: the hero is a large banner.
        if lead.newsHasResizablePhoto { s += 40 }
        return s
    }

    // MARK: - Preload & refresh

    /// Preloads the topic feeds so scrolling reveals ready content — deferred past first paint,
    /// hard-news (hero) topics first, capped to a few fetches in flight. Runs once (guarded); each
    /// `load` is cache-guarded so repeat home visits within the TTL are free.
    func preload() {
        guard isEnabled else { return }
        guard !preloadStarted else { return }
        preloadStarted = true
        let ordered = orderedTopics
        Task { @MainActor in
            try? await Task.sleep(for: Self.preloadStartDelay)
            await runBoundedLoad(ordered)
        }
    }

    /// Forces a fresh reload of every topic (manual pull-to-refresh + periodic auto-refresh). Bypasses
    /// the per-topic TTL but reuses the bounded/coalesced machinery; existing cards stay until replaced.
    func refresh() {
        guard isEnabled else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastFetched.removeAll()   // invalidate freshness so `load` refetches instead of TTL-skipping
        let ordered = orderedTopics
        Task { @MainActor in
            await runBoundedLoad(ordered)
            isRefreshing = false
        }
    }

    /// Hero (hard-news) topics first — they drive the top-story banner — then the rest, in declared order.
    /// Only visible (non-hidden) topics are loaded.
    private var orderedTopics: [Topic] {
        let visible = visibleTopics
        return Self.heroTopicIDs.compactMap { id in visible.first { $0.id == id } }
            + visible.filter { !Self.heroTopicIDs.contains($0.id) }
    }

    /// Runs `load` across `topics` with at most `preloadConcurrency` fetches in flight at once.
    private func runBoundedLoad(_ topics: [Topic]) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < topics.count else { return }
                let topic = topics[next]
                next += 1
                group.addTask { await self.load(topic) }
            }
            for _ in 0..<min(Self.preloadConcurrency, topics.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    // MARK: - Editorial filters (hero only)

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

    /// Drops everything from memory (feed switched off, Clear History, etc.).
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
