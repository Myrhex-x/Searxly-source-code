//
//  BookmarkURLMatcher.swift
//  Searxly
//
//  Canonical URL matching for bookmark add/remove/toggle.
//

import Foundation

/// Shared bookmark limits. Bookmarks are tiny (url + title + date), so the cap exists only as a sanity
/// bound — it must be high enough that a single manual bookmark can never truncate a bulk import.
enum BookmarkLimits {
    static let maxCount = 5000
}

enum BookmarkURLMatcher {

    static func canonicalKey(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        components.host = components.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        var path = components.path
        if path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
            components.path = path
        }
        return (components.string ?? trimmed).lowercased()
    }

    static func contains(url: String, in bookmarks: [BookmarkItem]) -> Bool {
        let key = canonicalKey(url)
        return bookmarks.contains { canonicalKey($0.url) == key }
    }

    static func remove(url: String, from bookmarks: inout [BookmarkItem]) {
        let key = canonicalKey(url)
        bookmarks.removeAll { canonicalKey($0.url) == key }
    }
}