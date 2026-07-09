//
//  ReadingListStore.swift
//  SearxlyiOS
//
//  Save-for-later reading list — a deliberate, curated set of pages (unlike history), kept ENCRYPTED
//  at rest in its own file via SecureLibraryStorage. Local only, no sync, no analytics. Survives
//  Clear History (it's a save, not a trace) — cleared only from its own screen or a full data wipe.
//

import Foundation
import Observation

struct ReadingItem: Identifiable, Codable, Equatable {
    let id: UUID
    let url: String
    var title: String
    let addedAt: Date
    var isRead: Bool

    init(id: UUID = UUID(), url: String, title: String, addedAt: Date = .now, isRead: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.addedAt = addedAt
        self.isRead = isRead
    }
}

@MainActor
@Observable
final class ReadingListStore {
    static let shared = ReadingListStore()

    private static let fileName = "ReadingList.enc"
    private static let cap = 300

    private(set) var items: [ReadingItem] = []

    private init() {
        items = SecureLibraryStorage.load([ReadingItem].self, from: Self.fileURL) ?? []
    }

    private static var fileURL: URL { SecureLibraryStorage.fileURL(name: fileName) }

    var unreadCount: Int { items.reduce(0) { $0 + ($1.isRead ? 0 : 1) } }

    func contains(_ url: String) -> Bool { items.contains { $0.url == url } }

    /// Adds if absent, removes if present. Returns the resulting membership (true = now saved).
    @discardableResult
    func toggle(url: String, title: String) -> Bool {
        if let idx = items.firstIndex(where: { $0.url == url }) {
            items.remove(at: idx)
            persist()
            return false
        }
        items.insert(ReadingItem(url: url, title: title.isEmpty ? url : title), at: 0)
        if items.count > Self.cap { items.removeLast(items.count - Self.cap) }
        persist()
        return true
    }

    func add(url: String, title: String) {
        guard !contains(url) else { return }
        _ = toggle(url: url, title: title)
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
    }

    func setRead(_ id: UUID, _ read: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isRead = read
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        SecureLibraryStorage.save(items, to: Self.fileURL)
    }

    #if DEBUG
    func seedDemo() {
        guard items.isEmpty else { return }
        items = [
            ReadingItem(url: "https://www.swift.org/blog/", title: "Swift.org — Blog"),
            ReadingItem(url: "https://en.wikipedia.org/wiki/Privacy", title: "Privacy — Wikipedia", isRead: true),
        ]
    }
    #endif
}
