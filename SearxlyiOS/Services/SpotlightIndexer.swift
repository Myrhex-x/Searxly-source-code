//
//  SpotlightIndexer.swift
//  SearxlyiOS
//
//  Indexes the user's bookmarks into CoreSpotlight so the system search (swipe-down on the Home
//  Screen) finds them; tapping a result opens the page in Searxly. Only bookmarks are indexed —
//  never history, never private-tab content — and everything stays on device (CoreSpotlight is a
//  local index). The whole set is rebuilt on every bookmark change, which is cheap at these counts.
//

import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

enum SpotlightIndexer {
    /// Namespaces our items so we can wipe/replace just ours, never touching other apps' index.
    static let domainID = "com.myrhex.searxly.bookmarks"

    /// Rebuilds the bookmark index from scratch. Called at launch and after any bookmark edit.
    static func reindexBookmarks() {
        let index = CSSearchableIndex.default()
        let items: [CSSearchableItem] = LibraryStore.shared.bookmarks.compactMap { bookmark in
            guard let url = URL(string: bookmark.url) else { return nil }
            let attrs = CSSearchableItemAttributeSet(contentType: .url)
            attrs.title = bookmark.title
            attrs.contentURL = url
            attrs.contentDescription = url.host
            attrs.identifier = bookmark.url
            return CSSearchableItem(
                uniqueIdentifier: bookmark.url,
                domainIdentifier: domainID,
                attributeSet: attrs
            )
        }
        // Replace our whole domain, then add the current set — order via nested completion so a
        // stale delete never races the fresh add.
        index.deleteSearchableItems(withDomainIdentifiers: [domainID]) { _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Drops every indexed bookmark (used when the user clears their library).
    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainID]) { _ in }
    }
}
