//
//  SearXNGModels.swift
//  SearxlyShared
//
//  SearXNG JSON SERP result models, moved out of the macOS SearXNGService so the iOS app
//  shares one definition (the service class itself stays macOS-only). Pure + portable.
//

import Foundation
import CoreGraphics

/// Options forwarded to the SearXNG JSON search API.
struct SearXNGSearchOptions: Sendable {
    /// Explicit nonisolated default — required for default parameter values on @MainActor methods (Swift 6).
    nonisolated static let standard = SearXNGSearchOptions(pageNo: 1, safeSearch: nil, timeRange: nil)

    var pageNo: Int
    var safeSearch: Int?
    var timeRange: String?

    init(pageNo: Int = 1, safeSearch: Int? = nil, timeRange: String? = nil) {
        self.pageNo = pageNo
        self.safeSearch = safeSearch
        self.timeRange = timeRange
    }
}

// MARK: - Response Models (kept here for service locality, also referenced from Models.swift via same module)

struct SearXNGResult: Decodable, Identifiable {
    var id: String { url }

    let title: String
    let url: String
    let content: String?
    let engine: String?

    // Additional fields for richer search result display (flat SERP redesign)
    let publishedDate: String?   // Present on some news/articles; surfaced as extra detail in result meta row
    let engines: [String]?       // Some responses include multiple contributing engines; single `engine` kept for primary display
    let metadata: String?        // Engine-supplied misc metadata; bing_news packs the source/outlet name here

    // Image / video specific fields returned by SearXNG when using categories=images or videos
    let img_src: String?        // Direct image URL (best for thumbnails / preview)
    let thumbnail: String?      // Sometimes a smaller dedicated thumb
    let thumbnail_src: String?  // Alternative thumb field some engines use
    let img_format: String?
    let resolution: String?
    let filesize: String?

    // Optional dimensions (emitted by some engines / SearXNG result types). Used for natural-aspect
    // Google-like image grid tiles instead of forcing square crops. Fall back to resolution string parse.
    let width: Int?
    let height: Int?
    let thumb_width: Int?
    let thumb_height: Int?

    enum CodingKeys: String, CodingKey {
        case title, url, content, engine, publishedDate, engines, metadata
        case img_src, thumbnail, thumbnail_src, img_format, resolution, filesize
        case width, height, thumb_width, thumb_height
    }
}

// MARK: - Display helpers & utilities (used by SearchResultCard and media grid for consistent, readable SERP)
// These are deliberately kept with the model for service locality (no new files, minimal surface).
// All are pure, zero-side-effect, and defensive (never crash on bad data from upstream engines).

extension SearXNGResult {
    /// www-stripped host for meta rows and deduping. Matches the spirit of the minimal web theme (netloc only).
    var displayHost: String {
        guard let u = URL(string: url), let host = u.host else { return url }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    /// Short, scannable path segment for the meta row when useful. Avoids dumping giant paths.
    /// Prefers host+short-path or host+…+tail. Falls back gracefully.
    var displayPath: String {
        guard let u = URL(string: url), u.host != nil else { return "" }
        let p = u.path
        if p.isEmpty || p == "/" { return "" }
        if p.count <= 32 {
            return p
        }
        // Middle ellipsis for long paths (more readable than crude prefix/suffix in flat row)
        let head = p.prefix(20)
        let tail = p.suffix(8)
        return String(head) + "…" + String(tail)
    }

    /// Primary engine for display (prefers the singular `engine` field, falls back to first of `engines`).
    var primaryEngine: String? {
        if let e = engine, !e.isEmpty { return e }
        return engines?.first
    }

    /// Compact engine attribution string for the meta row, e.g. "google", "google +2", or nil.
    /// Uses the multi-engine array when present (common with SearXNG aggregation).
    var enginesDisplay: String? {
        let list = (engines?.isEmpty == false ? engines : (engine.map { [$0] })) ?? []
        let cleaned = list.compactMap { $0.isEmpty ? nil : $0 }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count == 1 {
            return cleaned[0]
        }
        return "\(cleaned[0]) +\(cleaned.count - 1)"
    }

    /// Best-effort human presentation of publishedDate for news/articles.
    /// Tries common formats; always falls back to the raw (trimmed) string so we never lose info or crash.
    func formattedPublishedDate() -> String? {
        guard let raw = publishedDate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Fast path: already looks like a nice short human string from the engine
        if raw.count <= 24 && !raw.contains("T") && !raw.contains(":") {
            return raw
        }

        // Try ISO8601 / RFC3339 style
        if let date = Self.isoDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }

        // Fallback: common yyyy-MM-dd or yyyy/MM/dd
        if let date = Self.ymdDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }
        if let date = Self.ymdSlashDateFormatter.date(from: raw) {
            return Self.shortDateFormatter.string(from: date)
        }

        // Last resort: return the cleaned raw so the UI still shows *something* useful
        return raw
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static let ymdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let ymdSlashDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    // MARK: Media aspect (for Google-like natural proportion grids, not forced squares)
    /// Returns the best-known aspect ratio (width/height) for this result's thumbnail.
    /// Prefers explicit numeric width/height (or thumb_* variants), then parses the `resolution`
    /// string (supports "1920x1080", "1920 x 1080", "1920×1080"). Falls back to nil.
    /// Callers (MediaGridItem) use a category-appropriate default when this is nil.
    var thumbnailAspectRatio: CGFloat? {
        // Explicit dimensions first (some engines / result types surface these)
        if let w = width ?? thumb_width, let h = height ?? thumb_height, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        guard let raw = resolution?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        // Normalize separators
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
                           .replacingOccurrences(of: "×", with: "x")
                           .replacingOccurrences(of: "X", with: "x")
                           .lowercased()
        let parts = cleaned.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              h > 0 else { return nil }
        return CGFloat(w / h)
    }
}

/// Client-side deduplication by canonical URL (preserves first-seen order).
/// Replicates the exact pattern used in SearchMediaGrid so text results and media stay consistent.
/// Called from the view layer (or optionally BrowserState) before rendering the flat list.
extension SearXNGResult {
    static func deduplicated(_ results: [SearXNGResult]) -> [SearXNGResult] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.url).inserted }
    }
}

// MARK: - News recency & live signals
// The news SERP is recency-first. Two upstream realities shape this:
//   • Date-emitting engines (yahoo_news, reuters, hackernews, …) return an ISO `publishedDate`.
//   • google_news emits no machine date — it packs "Source / 2 hours ago" into `content`; bing_news
//     packs the outlet name into `metadata` and no date at all.
// So we parse BOTH absolute ISO timestamps and the relative phrases, recover an approximate `Date`,
// and derive a clean relative label ("8m ago"), a freshness tier (live/today/…), and the source name.
// Everything is pure, defensive, and returns nil rather than inventing a time we don't actually have.

/// How fresh a news item is, used to drive the LIVE badge and recency emphasis.
enum NewsFreshness {
    case live      // < 1 hour old — the "live"/just-published lane
    case today     // < 24 hours
    case recent    // < 7 days
    case older     // >= 7 days
    case unknown   // no parseable date — show source only, never a fake time
}

extension SearXNGResult {
    /// Best-effort absolute publish `Date`. Prefers a real ISO/RFC `publishedDate`; otherwise recovers
    /// an approximate time from a relative phrase (google_news' "Source / 2 hours ago" in `content`, or
    /// a relative `publishedDate` string some engines use). Returns nil when nothing parses.
    var newsPublishedDate: Date? {
        if let raw = publishedDate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let d = Self.parseAbsoluteNewsDate(raw) { return d }
            if let d = Self.parseRelativePhrase(raw) { return d }
        }
        // bing_news packs "<relative time> | <source>" into `metadata` (e.g. "2 minutes ago | Forbes").
        if let phrase = newsMetadataTimePhrase, let d = Self.parseRelativePhrase(phrase) { return d }
        // google_news packs "Source / 2 hours ago" into `content`.
        if let tail = newsContentTimePhrase, let d = Self.parseRelativePhrase(tail) { return d }
        return nil
    }

    /// Freshness bucket derived from `newsPublishedDate`. `.unknown` when we have no date at all.
    var newsFreshness: NewsFreshness {
        guard let d = newsPublishedDate else { return .unknown }
        let age = Date().timeIntervalSince(d)
        // "Live" means genuinely just-broke (~20 min) so the badge stays meaningful — a newest-first feed
        // is full of sub-hour stories, and tagging them all LIVE makes it noise.
        if age < 1200 { return .live }
        if age < 86_400 { return .today }
        if age < 7 * 86_400 { return .recent }
        return .older
    }

    /// Short human "time ago" label ("Just now", "8m ago", "3h ago", "Yesterday", "4d ago", or a date).
    /// nil when there's no parseable time — callers then show only the source, never a placeholder.
    var newsRelativeString: String? {
        guard let d = newsPublishedDate else { return nil }
        return Self.relativeNewsString(from: d)
    }

    /// Human outlet/source label: the engine's `metadata` (bing_news → "The Verge"), else the origin
    /// google_news packs before the "/", else the publisher host.
    var newsSourceName: String {
        // bing_news metadata is "<time> | <source>" (or just "<source>") — pick the segment that ISN'T
        // the timestamp, so we never show "2 minutes ago" where the outlet name belongs.
        if let source = newsMetadataSource, !source.isEmpty { return source }
        if let c = content, c.contains(" / "), let head = c.split(separator: "/").first {
            let s = head.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, s.count <= 40 { return s }
        }
        return displayHost
    }

    /// The snippet with google_news' "Source / time" boilerplate stripped (it's shown as source +
    /// timestamp chips instead). Real snippets (bing_news) pass through unchanged.
    var newsCleanSnippet: String? {
        guard let c = content?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        if newsContentTimePhrase != nil { return nil }
        return c
    }

    /// Whether the headline carries a genuine breaking-news flag AND isn't stale. Deliberately strict —
    /// it looks for the "Breaking:" / "Breaking news" marker outlets use, not the bare word "breaking"
    /// (so a query like "Breaking Bad" never lights up every row).
    var isBreakingNews: Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        let flagged = t.hasPrefix("breaking:")
            || t.hasPrefix("breaking -")
            || t.hasPrefix("breaking —")
            || t.hasPrefix("breaking |")
            || t.contains("breaking news")
        guard flagged else { return false }
        switch newsFreshness {
        case .live, .today, .unknown: return true
        case .recent, .older: return false
        }
    }

    // MARK: Internals

    /// The trailing relative-time phrase google_news packs into `content` ("Source / 2 hours ago").
    /// Only returns the tail when it is *itself* a clean, standalone relative phrase, so an article
    /// snippet that merely mentions "years ago" is never mistaken for a publish time.
    private var newsContentTimePhrase: String? {
        guard let c = content?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        let tail = c.contains(" / ")
            ? String(c.split(separator: "/").last ?? "").trimmingCharacters(in: .whitespaces)
            : c
        return Self.isPureRelativePhrase(tail) ? tail : nil
    }

    /// bing_news `metadata`, split on "|" into trimmed non-empty segments (e.g. ["2 minutes ago", "Forbes"]).
    private var metadataSegments: [String] {
        (metadata ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The segment of `metadata` that is a standalone relative-time phrase, if any.
    private var newsMetadataTimePhrase: String? {
        metadataSegments.first(where: { Self.isPureRelativePhrase($0) })
    }

    /// The segment of `metadata` that is the outlet name (the first non-time segment).
    private var newsMetadataSource: String? {
        metadataSegments.first(where: { !Self.isPureRelativePhrase($0) })
    }

    private static func parseAbsoluteNewsDate(_ raw: String) -> Date? {
        if let d = isoFractionalFormatter.date(from: raw) { return d }
        if let d = isoInternetFormatter.date(from: raw) { return d }
        if let d = pubdateFormatter.date(from: raw) { return d }
        if let d = newsYmdFormatter.date(from: raw) { return d }
        if let d = newsYmdSlashFormatter.date(from: raw) { return d }
        return nil
    }

    /// Whether `s` is entirely a relative-time phrase (anchored full match) — the gate that keeps prose
    /// out of the relative parser.
    private static func isPureRelativePhrase(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 24 else { return false }
        if ["just now", "now", "today", "yesterday"].contains(t) { return true }
        return t.range(
            of: #"^\d+\s*(mo|months?|minutes?|mins?|seconds?|secs?|hours?|hrs?|days?|weeks?|wks?|years?|yrs?|[smhdwy])\s*(ago)?$"#,
            options: .regularExpression
        ) != nil
    }

    /// Converts a relative phrase ("2 hours ago", "yesterday", "5m") into an approximate `Date`.
    /// Intended for already-validated phrases (see `isPureRelativePhrase`) or a non-ISO `publishedDate`.
    static func parseRelativePhrase(_ raw: String, now: Date = Date()) -> Date? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("just now") { return now }
        if s.contains("yesterday") { return now.addingTimeInterval(-86_400) }
        if let re = relativeRegex,
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           m.numberOfRanges >= 3,
           let numRange = Range(m.range(at: 1), in: s),
           let unitRange = Range(m.range(at: 2), in: s),
           let value = Double(s[numRange]) {
            return now.addingTimeInterval(-value * secondsPerUnit(String(s[unitRange])))
        }
        // "an hour ago" / "a minute ago" style (no digit).
        if s.contains("hour") { return now.addingTimeInterval(-3600) }
        if s.contains("min") { return now.addingTimeInterval(-60) }
        if s == "now" || s == "today" { return now }
        return nil
    }

    private static func secondsPerUnit(_ unit: String) -> TimeInterval {
        if unit.hasPrefix("mo") { return 30 * 86_400 }          // month(s) / "mo"
        if unit.hasPrefix("min") || unit == "m" { return 60 }   // minute(s) / "m"
        if unit.hasPrefix("s") { return 1 }                     // second(s)
        if unit.hasPrefix("h") { return 3600 }                  // hour(s)
        if unit.hasPrefix("d") { return 86_400 }                // day(s)
        if unit.hasPrefix("w") { return 7 * 86_400 }            // week(s)
        if unit.hasPrefix("y") { return 365 * 86_400 }          // year(s)
        return 60
    }

    static func relativeNewsString(from date: Date, now: Date = Date()) -> String {
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 60 { return "Just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m ago" }
        let hours = Int(secs / 3600)
        if hours < 24 { return "\(hours)h ago" }
        let days = Int(secs / 86_400)
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        return relativeShortDateFormatter.string(from: date)
    }

    private static let relativeRegex = try? NSRegularExpression(
        pattern: #"(\d+)\s*(mo|months?|minutes?|mins?|seconds?|secs?|hours?|hrs?|days?|weeks?|wks?|years?|yrs?|[smhdwy])"#,
        options: []
    )

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoInternetFormatter = ISO8601DateFormatter()

    private static let pubdateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssZ"   // SearXNG's `pubdate` string form
        return f
    }()

    private static let newsYmdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let newsYmdSlashFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    private static let relativeShortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - News thumbnail resolution
// News engines hand back tiny thumbnails (bing_news 234×132, google_news 100×100) that look soft when
// scaled up to a hero banner. Both encode the size in the URL — bing as `&w=&h=` query params, google
// as a `-w{W}-h{H}` suffix — so we simply request the display size. The original tiny URL is kept as a
// fallback candidate in case a service rejects the larger request.

extension SearXNGResult {
    /// First non-empty raw thumbnail field (bing_news/google_news populate `thumbnail`).
    var rawThumbnailURLString: String? {
        for field in [thumbnail_src, thumbnail, img_src] {
            let t = field?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Whether the thumbnail is a real, resizable story photo (bing/google image services) rather than a
    /// tiny fixed-size or logo thumbnail (e.g. reuters serves 80px images / its own logo). Used to keep
    /// the visual home feed sharp — only these upscale cleanly to card/hero size.
    var newsHasResizablePhoto: Bool {
        guard let raw = rawThumbnailURLString?.lowercased() else { return false }
        return (raw.contains("/th?") && raw.contains("bing.")) || raw.contains("news.google.com")
    }

    /// Recent enough to belong in a "live" home feed (has a parseable date within the last week).
    var isRecentNews: Bool {
        switch newsFreshness {
        case .live, .today, .recent: return true
        case .older, .unknown: return false
        }
    }

    /// Thumbnail candidates sized (roughly) to `width`×`height` px, sharpest first, original last.
    func newsThumbnailCandidates(width: Int, height: Int) -> [URL] {
        guard let raw = rawThumbnailURLString else { return [] }
        var out: [URL] = []
        let sized = Self.resizedThumbnailURLString(raw, width: width, height: height)
        if sized != raw, let u = URL(string: sized) { out.append(u) }
        if let u = URL(string: raw) { out.append(u) }
        return out
    }

    static func resizedThumbnailURLString(_ url: String, width: Int, height: Int) -> String {
        // Bing image resizer: …/th?id=…&w=234&h=132&c=14&rs=2&qlt=90
        if url.contains("/th?"), url.contains("bing.") {
            var s = url
            s = replaceURLIntParam(s, "w", width)
            s = replaceURLIntParam(s, "h", height)
            s = replaceURLIntParam(s, "qlt", 95)
            return s
        }
        // Google News attachments: …/attachments/XXXX=-w100-h100-p-df-rw
        if url.contains("news.google.com"),
           let re = try? NSRegularExpression(pattern: #"-w\d+-h\d+"#) {
            let range = NSRange(url.startIndex..., in: url)
            if let m = re.firstMatch(in: url, range: range), let mr = Range(m.range, in: url) {
                return url.replacingCharacters(in: mr, with: "-w\(width)-h\(height)")
            }
        }
        return url
    }

    /// Rewrites a `?name=NNN` / `&name=NNN` integer query param, reconstructed manually (an NSRegex
    /// template `$1\(value)` would be misread as capture group `$1NNN`).
    private static func replaceURLIntParam(_ url: String, _ name: String, _ value: Int) -> String {
        guard let re = try? NSRegularExpression(pattern: "[?&]\(name)=\\d+"),
              let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let mr = Range(m.range, in: url),
              let sep = url[mr].first else { return url }
        return url.replacingCharacters(in: mr, with: "\(sep)\(name)=\(value)")
    }
}

struct SearXNGResponse: Decodable {
    let query: String?
    let results: [SearXNGResult]?
    /// SearXNG's own "related searches" — real, relevant refinement queries returned with the
    /// JSON response. Used as AI-Overview follow-ups (free, no model cost) and query suggestions.
    let suggestions: [String]?
}