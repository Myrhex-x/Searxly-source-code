//
//  SearchQueryHistoryStore.swift
//  Searxly
//
//  Persists past search queries for re-surfacing them in address bar suggestions.
//  Stored in UserDefaults (not AppData.json) to avoid heavy read-modify-write on every keystroke.
//  Independent from the browsing URL history toggle — users can disable URL history but still
//  have search query suggestions, or vice versa.
//

import Foundation

struct SearchQueryRecord: Codable {
    let query: String
    let date: Date
}

final class SearchQueryHistoryStore {
    static let shared = SearchQueryHistoryStore()
    private init() {}

    private static let defaultsKey = "Searxly.SearchQueryHistory"
    private static let maxEntries = 200
    static let enabledKey = "searchQueryHistoryEnabled"

    /// In-memory copy of the decoded entries so the per-keystroke `matching()` read never re-hits the
    /// Keychain / AES-GCM decrypt path (that would add latency in the address bar when at-rest encryption
    /// is on). Populated on first access and kept in sync by every write. Guarded by `lock` because the
    /// singleton is not actor-isolated. `nil` = "not loaded yet".
    private let lock = NSLock()
    private var cache: [SearchQueryRecord]?

    // MARK: - Write

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 2 else { return }
        var entries = load()
        // Deduplicate case-insensitively; move existing match to front with fresh timestamp.
        entries.removeAll { $0.query.lowercased() == trimmed.lowercased() }
        entries.insert(SearchQueryRecord(query: trimmed, date: Date()), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save(entries)
    }

    // MARK: - Query

    /// Returns past queries that start with `prefix`, most recent first, up to `max`.
    /// Excludes an exact case-insensitive match (the typed search row already covers that).
    func matching(_ prefix: String, max: Int = 5) -> [SearchQueryRecord] {
        let q = prefix.lowercased()
        guard !q.isEmpty else { return [] }
        return load()
            .filter { $0.query.lowercased().hasPrefix(q) && $0.query.lowercased() != q }
            .prefix(max)
            .map { $0 }
    }

    // MARK: - Clear

    func clearAll() {
        lock.lock()
        cache = []
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Private

    private func load() -> [SearchQueryRecord] {
        lock.lock()
        if let cached = cache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let entries = decodeFromDisk()
        lock.lock()
        cache = entries
        lock.unlock()
        return entries
    }

    /// Reads + decodes the persisted blob. Handles both plaintext (legacy / encryption-off) and AES-GCM
    /// blobs written while "Encrypt local data at rest" is on. A failed decrypt (e.g. key unavailable)
    /// degrades to empty rather than throwing — search suggestions are non-critical.
    private func decodeFromDisk() -> [SearchQueryRecord] {
        guard let raw = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return [] }
        let jsonData: Data
        if EncryptedDataStore.looksEncrypted(raw) {
            guard let decrypted = try? DataEncryptor.decryptWithStoredKey(raw) else { return [] }
            jsonData = decrypted
        } else {
            jsonData = raw
        }
        return (try? JSONDecoder().decode([SearchQueryRecord].self, from: jsonData)) ?? []
    }

    private func save(_ entries: [SearchQueryRecord]) {
        lock.lock()
        cache = entries
        lock.unlock()

        guard let jsonData = try? JSONEncoder().encode(entries) else { return }
        // Mirror the main store's contract: when at-rest encryption is enabled, encrypt this blob too and
        // NEVER fall back to plaintext if the key is unavailable — that would silently defeat the setting.
        if EncryptedDataStore.isEncryptionEnabled() {
            guard let encrypted = try? DataEncryptor.encryptWithStoredKey(jsonData) else { return }
            UserDefaults.standard.set(encrypted, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(jsonData, forKey: Self.defaultsKey)
        }
    }
}
