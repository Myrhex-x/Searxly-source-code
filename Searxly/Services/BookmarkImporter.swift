//
//  BookmarkImporter.swift
//  Searxly
//
//  Imports bookmarks from other browsers via the universal Netscape "bookmarks.html" export format
//  that Safari, Chrome, Firefox, Edge, Brave, Arc, etc. all produce from their "Export Bookmarks…"
//  command. This single format is why we don't need browser-specific readers (and reading another
//  browser's profile directly is blocked by the App Sandbox anyway).
//
//  Sandbox-safe: the user picks the file through an NSOpenPanel, which grants this app read access to
//  exactly that one file (the app holds the user-selected.read-write entitlement).
//

import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
enum BookmarkImporter {
    struct Summary {
        let imported: Int   // newly added
        let skipped: Int    // already present (deduped)
        let total: Int      // bookmarks found in the file
    }

    /// Shows the open panel and returns the chosen HTML file (main thread). nil if cancelled.
    static func pickBookmarksFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Choose a bookmarks file exported from another browser (File → Export Bookmarks…)."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html]

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Reads + parses the file off the main thread, then merges new bookmarks into `existing`
    /// (de-duplicated by normalized URL). Imported bookmarks are **prepended** (most-recent first) so
    /// they immediately surface in the sidebar, bookmarks bar, and list, and the whole list is capped at
    /// BookmarkLimits.maxCount. Returns the merged array plus a summary.
    static func importBookmarks(from url: URL, mergingInto existing: [BookmarkItem]) async -> (bookmarks: [BookmarkItem], summary: Summary) {
        // Heavy regex parse runs off the main actor so large exports never jank the UI.
        let parsed: [ParsedBookmark] = await Task.detached(priority: .userInitiated) {
            // NSOpenPanel URLs can be security-scoped in the sandbox; without this the read can fail.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let html = readText(at: url) else { return [] }
            return parseNetscapeBookmarks(html)
        }.value

        guard !parsed.isEmpty else {
            return (existing, Summary(imported: 0, skipped: 0, total: 0))
        }

        var importedItems: [BookmarkItem] = []
        var skipped = 0
        for entry in parsed {
            if BookmarkURLMatcher.contains(url: entry.url, in: existing) {
                skipped += 1
            } else {
                importedItems.append(BookmarkItem(url: entry.url, title: entry.title, dateAdded: entry.dateAdded))
            }
        }

        // Newest-created imported bookmark first, then the user's existing list beneath.
        importedItems.sort { $0.dateAdded > $1.dateAdded }
        var merged = importedItems + existing
        if merged.count > BookmarkLimits.maxCount {
            merged.removeLast(merged.count - BookmarkLimits.maxCount)
        }
        return (merged, Summary(imported: importedItems.count, skipped: skipped, total: parsed.count))
    }

    // MARK: - Parsing

    struct ParsedBookmark: Sendable {
        let url: String
        let title: String
        let dateAdded: Date
    }

    /// Extracts `<A HREF="…" ADD_DATE="…">Title</A>` anchors from Netscape-format bookmark HTML.
    /// Deliberately tolerant: attribute order and quoting vary between browsers, titles may contain
    /// HTML entities, and folder structure (`<H3>`) is ignored — BrowserState stores a flat list.
    nonisolated static func parseNetscapeBookmarks(_ html: String) -> [ParsedBookmark] {
        guard let anchorRegex = try? NSRegularExpression(
            pattern: #"<a\s+([^>]*?)>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let hrefRegex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive])
        let addDateRegex = try? NSRegularExpression(pattern: #"add_date\s*=\s*["']?(\d+)["']?"#, options: [.caseInsensitive])

        let ns = html as NSString
        var out: [ParsedBookmark] = []
        var seen = Set<String>()

        anchorRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let attrs = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let attrsNS = attrs as NSString

            guard let hrefMatch = hrefRegex?.firstMatch(in: attrs, range: NSRange(location: 0, length: attrsNS.length)) else { return }
            let urlStr = decodeEntities(attrsNS.substring(with: hrefMatch.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Keep only real web bookmarks; skip javascript:, place:, data:, file:, and empties.
            guard let scheme = URL(string: urlStr)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            // De-dupe within the file itself too.
            guard seen.insert(urlStr).inserted else { return }

            let strippedTitle = decodeEntities(stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = strippedTitle.isEmpty ? (URL(string: urlStr)?.host ?? urlStr) : strippedTitle

            var date = Date()
            if let addDateRegex,
               let dateMatch = addDateRegex.firstMatch(in: attrs, range: NSRange(location: 0, length: attrsNS.length)),
               let seconds = Double(attrsNS.substring(with: dateMatch.range(at: 1))) {
                let parsedDate = Date(timeIntervalSince1970: seconds)
                // Guard against absurd/future timestamps from odd exporters.
                date = (parsedDate > Date() || seconds <= 0) ? Date() : parsedDate
            }

            out.append(ParsedBookmark(url: urlStr, title: title, dateAdded: date))
        }
        return out
    }

    // MARK: - Helpers

    /// Reads the file as text, tolerating non-UTF8 exports (some older browsers emit Latin-1).
    nonisolated private static func readText(at url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        if let data = try? Data(contentsOf: url) {
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    nonisolated private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    nonisolated private static func decodeEntities(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (key, value) in map { t = t.replacingOccurrences(of: key, with: value) }
        return t
    }
}
