//
//  CommandPalette.swift
//  Searxly
//
//  Pure logic for the ⌘K command palette: the result model, a small fuzzy matcher, and the builder
//  that turns the current browser state (open tabs, bookmarks, history) + the typed query into a
//  ranked list of results. Kept free of SwiftUI so it can be unit-tested in isolation.
//

import Foundation

// MARK: - Result model

/// What activating a palette result does.
enum PaletteAction: Equatable {
    case switchToTab(UUID)
    case openURL(URL)
    case search(String)
    case command(PaletteCommand)
}

/// The fixed quick actions the palette can run. Titles/icons/keywords live here so the builder and the
/// view stay in sync.
enum PaletteCommand: String, CaseIterable, Identifiable {
    case newTab
    case newPrivateTab
    case bookmarks
    case downloads
    case settings
    case importData
    case clearData
    case lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab:        return "New Tab"
        case .newPrivateTab: return "New Private Tab"
        case .bookmarks:     return "Bookmarks & History"
        case .downloads:     return "Downloads"
        case .settings:      return "Settings"
        case .importData:    return "Import Data from Another Browser"
        case .clearData:     return "Clear Browsing Data"
        case .lock:          return "Lock Searxly"
        }
    }

    var systemImage: String {
        switch self {
        case .newTab:        return "plus.square"
        case .newPrivateTab: return "shield.lefthalf.filled"
        case .bookmarks:     return "bookmark"
        case .downloads:     return "arrow.down.circle"
        case .settings:      return "gearshape"
        case .importData:    return "square.and.arrow.down.on.square"
        case .clearData:     return "trash"
        case .lock:          return "lock"
        }
    }

    /// Extra terms (beyond the title) that should match this command when typed.
    var keywords: [String] {
        switch self {
        case .newTab:        return ["open", "tab"]
        case .newPrivateTab: return ["incognito", "private", "ephemeral", "tab"]
        case .bookmarks:     return ["history", "favorites", "saved"]
        case .downloads:     return ["files", "saved"]
        case .settings:      return ["preferences", "options", "config"]
        case .importData:    return ["import", "migrate", "switch", "bookmarks", "passwords", "chrome", "safari", "firefox"]
        case .clearData:     return ["wipe", "cookies", "cache", "privacy"]
        case .lock:          return ["lock", "privacy", "secure"]
        }
    }
}

/// A single row in the palette.
struct PaletteResult: Identifiable {
    enum Group { case tab, bookmark, history, command, openURL, search }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let group: Group
    let action: PaletteAction
    /// Match score for the current query (higher = better). Used for sorting only.
    var score: Double

    /// Short tag shown on the right (e.g. "Tab", "Bookmark"). nil hides it.
    var badge: String? {
        switch group {
        case .tab:      return "Tab"
        case .bookmark: return "Bookmark"
        case .history:  return "History"
        case .command:  return "Action"
        case .openURL:  return "Open"
        case .search:   return "Search"
        }
    }
}

// MARK: - Fuzzy matching

enum PaletteFuzzy {
    /// Returns a score in (0, 1] when `query` matches `text`, or nil when it doesn't.
    /// Ranking, best → worst: exact, prefix, word-boundary substring, plain substring, subsequence.
    static func score(query: String, in text: String) -> Double? {
        let q = query.lowercased()
        let t = text.lowercased()
        guard !q.isEmpty else { return 0.001 }   // empty query matches everything weakly
        guard !t.isEmpty else { return nil }

        if t == q { return 1.0 }
        if t.hasPrefix(q) { return 0.92 }

        if let range = t.range(of: q) {
            // Boost when the match starts at a word boundary (after a space, '.', '/', '-', '_').
            let boundaries: Set<Character> = [" ", ".", "/", "-", "_", ":"]
            let atBoundary = range.lowerBound == t.startIndex
                || boundaries.contains(t[t.index(before: range.lowerBound)])
            let base = atBoundary ? 0.82 : 0.68
            // Slight penalty the further into the string the match begins.
            let pos = t.distance(from: t.startIndex, to: range.lowerBound)
            let penalty = min(0.12, Double(pos) / 200.0)
            return base - penalty
        }

        // Subsequence fallback (characters appear in order but not contiguously).
        if let subseq = subsequenceScore(q, t) { return subseq }
        return nil
    }

    /// Convenience: best score across several fields (e.g. title + url + keywords).
    static func bestScore(query: String, fields: [String], weights: [Double]? = nil) -> Double? {
        var best: Double? = nil
        for (i, field) in fields.enumerated() {
            guard let s = score(query: query, in: field) else { continue }
            let weighted = s * (weights?[safe: i] ?? 1.0)
            if best == nil || weighted > best! { best = weighted }
        }
        return best
    }

    private static func subsequenceScore(_ q: String, _ t: String) -> Double? {
        var qi = q.startIndex
        var matched = 0
        for ch in t {
            if qi < q.endIndex && ch == q[qi] {
                qi = q.index(after: qi)
                matched += 1
                if qi == q.endIndex { break }
            }
        }
        guard qi == q.endIndex else { return nil }
        // Density of matched chars over the text length → keeps "gh" from scoring a huge page title high.
        let density = Double(matched) / Double(max(t.count, 1))
        return 0.25 + min(0.2, density * 0.2)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Builder

enum CommandPaletteBuilder {
    /// Caps to keep the list snappy and scannable.
    private static let maxResults = 40
    private static let maxHistoryEmpty = 6
    private static let maxTabsEmpty = 8

    /// Builds the ranked result list.
    /// - Parameters:
    ///   - query: raw text from the palette field.
    ///   - tabs: open browser tabs.
    ///   - selectedTabID: the currently active tab (so it can be de-emphasised / labelled).
    ///   - bookmarks: saved bookmarks.
    ///   - history: visit history (most-recent-last, like BrowserState stores it).
    ///   - detectedURL: result of BrowserState.smartURL(query) — non-nil when the query looks like a URL.
    static func build(
        query rawQuery: String,
        tabs: [BrowserTab],
        selectedTabID: UUID?,
        bookmarks: [BookmarkItem],
        history: [HistoryItem],
        detectedURL: URL?
    ) -> [PaletteResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = query.isEmpty

        var results: [PaletteResult] = []

        // --- Open tabs (only real web tabs with somewhere to go, plus utility tabs) ---
        for tab in tabs {
            let isCurrent = tab.id == selectedTabID
            let urlString = tab.pageURLString
            let title = tab.title.isEmpty ? (URL(string: urlString)?.host ?? "New Tab") : tab.title
            let fields = [title, urlString]
            let matchScore = isEmpty ? 0.5 : PaletteFuzzy.bestScore(query: query, fields: fields, weights: [1.0, 0.7])
            guard let s = matchScore else { continue }
            // Current tab is rarely the thing you're jumping to — nudge it down.
            let adjusted = s - (isCurrent ? 0.15 : 0.0)
            results.append(PaletteResult(
                id: "tab-\(tab.id.uuidString)",
                title: title,
                subtitle: isCurrent ? "Current tab" : (urlString.isEmpty ? nil : prettyURL(urlString)),
                systemImage: tab.isPrivate ? "shield.lefthalf.filled" : (tab.kind == .web ? "square.on.square" : tab.kind.utilityIcon),
                group: .tab,
                action: .switchToTab(tab.id),
                score: adjusted + 0.25   // tabs are the primary use of the palette → slight global boost
            ))
        }

        // --- Bookmarks ---
        let bookmarkURLs = Set(bookmarks.map { $0.url })
        for bm in bookmarks {
            let fields = [bm.title, bm.url]
            let matchScore = isEmpty ? nil : PaletteFuzzy.bestScore(query: query, fields: fields, weights: [1.0, 0.75])
            // Show some bookmarks even with an empty query (most recent first).
            guard let s = (isEmpty ? 0.4 : matchScore), let url = URL(string: bm.url) else { continue }
            results.append(PaletteResult(
                id: "bm-\(bm.url)",
                title: bm.title.isEmpty ? (url.host ?? bm.url) : bm.title,
                subtitle: prettyURL(bm.url),
                systemImage: "bookmark.fill",
                group: .bookmark,
                action: .openURL(url),
                score: s
            ))
        }

        // --- History (dedup by URL, skip anything already shown as a bookmark, most-recent first) ---
        var seenHistory = Set<String>()
        for item in history.reversed() {
            guard !bookmarkURLs.contains(item.url), !seenHistory.contains(item.url) else { continue }
            let fields = [item.title, item.url]
            let matchScore = isEmpty ? nil : PaletteFuzzy.bestScore(query: query, fields: fields, weights: [1.0, 0.8])
            guard let s = (isEmpty ? 0.3 : matchScore), let url = URL(string: item.url) else { continue }
            seenHistory.insert(item.url)
            results.append(PaletteResult(
                id: "hist-\(item.url)",
                title: item.title.isEmpty ? (url.host ?? item.url) : item.title,
                subtitle: prettyURL(item.url),
                systemImage: "clock.arrow.circlepath",
                group: .history,
                action: .openURL(url),
                score: s * 0.95   // history slightly below bookmarks at equal text match
            ))
        }

        // --- Quick actions ---
        for cmd in PaletteCommand.allCases {
            let matchScore = isEmpty ? 0.45 : PaletteFuzzy.bestScore(query: query, fields: [cmd.title] + cmd.keywords, weights: nil)
            guard let s = matchScore else { continue }
            results.append(PaletteResult(
                id: "cmd-\(cmd.rawValue)",
                title: cmd.title,
                subtitle: nil,
                systemImage: cmd.systemImage,
                group: .command,
                action: .command(cmd),
                score: s
            ))
        }

        // Sort by score, then apply per-group caps for the empty state so the default list stays tidy.
        results.sort { $0.score > $1.score }

        if isEmpty {
            results = applyEmptyStateCaps(results)
        } else {
            results = Array(results.prefix(maxResults))
        }

        // --- Synthesized "open this URL" / "search for this" rows (only while typing) ---
        if !isEmpty {
            if let url = detectedURL {
                results.insert(PaletteResult(
                    id: "open-url",
                    title: "Open \(prettyURL(url.absoluteString))",
                    subtitle: url.absoluteString,
                    systemImage: "arrow.up.forward.app",
                    group: .openURL,
                    action: .openURL(url),
                    score: 100   // pinned to the very top — an explicit URL is an unambiguous intent
                ), at: 0)
            }
            // Always offer a search fallback, pinned to the bottom.
            results.append(PaletteResult(
                id: "search",
                title: "Search “\(query)”",
                subtitle: "Private search via SearXNG",
                systemImage: "magnifyingglass",
                group: .search,
                action: .search(query),
                score: -1
            ))
        }

        return results
    }

    private static func applyEmptyStateCaps(_ results: [PaletteResult]) -> [PaletteResult] {
        var tabs: [PaletteResult] = []
        var history: [PaletteResult] = []
        var others: [PaletteResult] = []
        for r in results {
            switch r.group {
            case .tab:     if tabs.count < maxTabsEmpty { tabs.append(r) }
            case .history: if history.count < maxHistoryEmpty { history.append(r) }
            default:       others.append(r)
            }
        }
        // Tabs first (the main use), then commands/bookmarks, then a few recent history rows.
        return tabs + others + history
    }

    /// Compact URL for subtitles: drop scheme + "www." and any trailing slash.
    static func prettyURL(_ raw: String) -> String {
        var s = raw
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
