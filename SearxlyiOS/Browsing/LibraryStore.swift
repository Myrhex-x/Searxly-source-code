//
//  LibraryStore.swift
//  SearxlyiOS
//
//  Bookmarks + browsing history — local only, no iCloud, no analytics. History is capped and easy
//  to clear (Settings ▸ Privacy). Persisted ENCRYPTED at rest (AES-GCM, device-only Keychain key)
//  via SecureLibraryStorage — macOS-parity with EncryptedDataStore; plaintext UserDefaults JSON
//  from earlier builds is migrated on first launch and removed.
//

import Foundation
import Observation
import UIKit

struct Bookmark: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    var title: String
    let addedAt: Date
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let url: String
    var title: String
    let visitedAt: Date

    init(id: UUID = UUID(), url: String, title: String, visitedAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}

/// A private address-bar suggestion sourced ONLY from local bookmarks/history (no network, no query
/// ever leaves the device — unlike a search-engine autocomplete that would leak every keystroke).
struct Suggestion: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let url: String
}

@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private static let legacyBookmarksKey = "searxly.ios.bookmarks"
    private static let legacyHistoryKey = "searxly.ios.history"
    private static let historyCap = 600

    /// On-disk shape of the encrypted library file.
    private struct LibraryData: Codable {
        var bookmarks: [Bookmark]
        var history: [HistoryEntry]
        // Added later — optional so pre-existing encrypted files still decode.
        var recentSearches: [String]?
    }

    private(set) var bookmarks: [Bookmark] = []
    private(set) var history: [HistoryEntry] = []
    /// Recent search queries, newest first (encrypted with the rest; cleared with history).
    private(set) var recentSearches: [String] = []
    private static let recentSearchesCap = 20

    private init() {
        if let data = SecureLibraryStorage.load(LibraryData.self) {
            bookmarks = data.bookmarks
            history = data.history
            recentSearches = data.recentSearches ?? []
        } else {
            migrateFromLegacyDefaults()
        }
    }

    /// One-time migration from the pre-encryption UserDefaults JSON. The plaintext copies are
    /// removed only after the encrypted file has been written successfully.
    private func migrateFromLegacyDefaults() {
        let defaults = UserDefaults.standard
        let legacyBookmarks = Self.loadLegacy([Bookmark].self, key: Self.legacyBookmarksKey)
        let legacyHistory = Self.loadLegacy([HistoryEntry].self, key: Self.legacyHistoryKey)
        guard legacyBookmarks != nil || legacyHistory != nil else { return }

        bookmarks = legacyBookmarks ?? []
        history = legacyHistory ?? []
        if SecureLibraryStorage.save(LibraryData(bookmarks: bookmarks, history: history)) {
            defaults.removeObject(forKey: Self.legacyBookmarksKey)
            defaults.removeObject(forKey: Self.legacyHistoryKey)
        }
    }

    // MARK: - Bookmarks

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    @discardableResult
    func toggleBookmark(url: String, title: String) -> Bool {
        if let idx = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: idx)
            persistBookmarks()
            return false
        }
        bookmarks.insert(Bookmark(url: url, title: title.isEmpty ? url : title, addedAt: .now), at: 0)
        persistBookmarks()
        return true
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        persistBookmarks()
    }

    // MARK: - History

    /// Records a visit, collapsing consecutive duplicates and moving an existing URL to the top.
    func recordVisit(url: String, title: String) {
        guard let u = URL(string: url), let scheme = u.scheme, scheme.hasPrefix("http") else { return }
        if history.first?.url == url {
            if !title.isEmpty { history[0].title = title }
            persistHistory()
            return
        }
        history.removeAll { $0.url == url }
        history.insert(HistoryEntry(url: url, title: title.isEmpty ? (u.host ?? url) : title), at: 0)
        if history.count > Self.historyCap { history.removeLast(history.count - Self.historyCap) }
        persistHistory()
    }

    /// Updates the title of the most-recent entry for a URL once the page title resolves.
    func updateTitle(url: String, title: String) {
        guard !title.isEmpty, let idx = history.firstIndex(where: { $0.url == url }) else { return }
        history[idx].title = title
        persistHistory()
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        recentSearches.removeAll()
        persistHistory()
        // Favicons are browsing traces too — clearing history clears them with it
        // (bookmarked sites re-earn their icon on the next visit).
        FaviconStore.shared.clearAll()
    }

    // MARK: - Recent searches

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > Self.recentSearchesCap {
            recentSearches.removeLast(recentSearches.count - Self.recentSearchesCap)
        }
        persist()
    }

    func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        persist()
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        persist()
    }

    // MARK: - Sync (device-to-device, encrypted, no server)

    func exportSyncBundle() -> SyncBundle {
        SyncBundle(
            bookmarks: bookmarks.map { SyncBookmark(url: $0.url, title: $0.title, addedAt: $0.addedAt) },
            history: history.map { SyncHistoryItem(url: $0.url, title: $0.title, visitedAt: $0.visitedAt) },
            deviceName: UIDevice.current.name
        )
    }

    /// Merges an incoming bundle into the local library (union, newest wins). Returns how many
    /// NEW items landed, so the UI can report "added 12 bookmarks, 40 history items".
    @discardableResult
    func importSyncBundle(_ bundle: SyncBundle) -> (bookmarks: Int, history: Int) {
        let localBookmarks = bookmarks.map { SyncBookmark(url: $0.url, title: $0.title, addedAt: $0.addedAt) }
        let localHistory = history.map { SyncHistoryItem(url: $0.url, title: $0.title, visitedAt: $0.visitedAt) }

        let existingBookmarkURLs = Set(bookmarks.map(\.url))
        let existingHistoryURLs = Set(history.map(\.url))
        let newBookmarks = bundle.bookmarks.filter { !existingBookmarkURLs.contains($0.url) }.count
        let newHistory = bundle.history.filter { !existingHistoryURLs.contains($0.url) }.count

        let mergedBookmarks = SyncMerge.bookmarks(localBookmarks, bundle.bookmarks)
        let mergedHistory = SyncMerge.history(localHistory, bundle.history)

        bookmarks = mergedBookmarks.map { Bookmark(url: $0.url, title: $0.title, addedAt: $0.addedAt) }
        history = Array(mergedHistory.prefix(Self.historyCap))
            .map { HistoryEntry(url: $0.url, title: $0.title, visitedAt: $0.visitedAt) }
        persist()
        return (newBookmarks, newHistory)
    }

    // MARK: - Suggestions (private, local-only)

    /// Relevant bookmarks + history for the query, ranked. Matching is by PREFIX on meaningful tokens
    /// (the host, its domain labels with the TLD excluded, and title words) — NOT a loose substring,
    /// so a query like "co" doesn't match every ".com" URL or the "co" inside "Welcome".
    func suggestions(for query: String, limit: Int = 6) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var scored: [(suggestion: Suggestion, score: Int, order: Int)] = []
        var seen = Set<String>()
        var order = 0

        func consider(title: String, url: String, icon: String, bookmarkBonus: Int) {
            guard !seen.contains(url), let base = Self.matchScore(query: q, title: title, url: url) else { return }
            seen.insert(url)
            scored.append((Suggestion(id: url, icon: icon, title: title, url: url), base + bookmarkBonus, order))
            order += 1
        }

        for b in bookmarks { consider(title: b.title, url: b.url, icon: "bookmark.fill", bookmarkBonus: 1) }
        for h in history  { consider(title: h.title, url: h.url, icon: "clock", bookmarkBonus: 0) }

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map(\.suggestion)
    }

    /// Prefix relevance. Highest: the host starts with the query; then a domain label (TLD excluded)
    /// starts with it; then a word in the title. nil = no meaningful match.
    private static func matchScore(query q: String, title: String, url: String) -> Int? {
        var score = 0
        let host = (URL(string: url)?.host ?? "")
            .replacingOccurrences(of: "www.", with: "")
            .lowercased()
        if !host.isEmpty {
            if host.hasPrefix(q) { score = max(score, 4) }
            let labels = host.split(separator: ".")
            let domainLabels = labels.count > 1 ? Array(labels.dropLast()) : labels
            if domainLabels.contains(where: { $0.hasPrefix(q) }) { score = max(score, 3) }
        }
        let titleWords = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if titleWords.contains(where: { $0.hasPrefix(q) }) { score = max(score, 2) }
        return score > 0 ? score : nil
    }

    // MARK: - Persistence (encrypted, synchronous — durability is never deferred)

    private func persistBookmarks() { persist() }
    private func persistHistory() { persist() }

    private func persist() {
        SecureLibraryStorage.save(LibraryData(
            bookmarks: bookmarks, history: history, recentSearches: recentSearches
        ))
    }

    private static func loadLegacy<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
