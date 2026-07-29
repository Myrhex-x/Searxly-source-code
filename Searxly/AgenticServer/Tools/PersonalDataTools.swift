//
//  PersonalDataTools.swift
//  Searxly — Agentic Tools
//
//  The "personal data" tier: lets a user's local AI search their browsing history and bookmarks and
//  save new bookmarks — "what was that article about X I read last week?" answered locally. All three
//  tools set `requiresPersonalData = true`, so they're hidden + refused until the user turns on the
//  separate "Personal data" opt-in in Settings. Everything reads/writes BrowserState's existing
//  stores; nothing new is persisted and nothing leaves the machine.
//

import Foundation

@MainActor
enum PersonalDataSupport {
    /// Case-insensitive match: every whitespace-separated token of `query` must appear in `haystack`.
    static func matches(_ query: String, in haystack: String) -> Bool {
        let tokens = query.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func maxResults(_ arguments: [String: Any], default def: Int) -> Int {
        min(max(AgenticToolFormat.intArg(arguments["max_results"]) ?? def, 1), 50)
    }

    static let iso = ISO8601DateFormatter()

    static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    /// JSON Schema for a list-of-records result: { query, count, results: [ { fields… } ] }.
    static func listSchema(_ recordProps: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": [
            "query": ["type": "string"],
            "count": ["type": "integer"],
            "results": ["type": "array", "items": ["type": "object", "properties": recordProps]]
        ]]
    }
}

// MARK: - search_history

@MainActor
struct SearchHistoryTool: AgenticTool {
    let id = "search_history"
    let title = "Search history"
    let requiresPersonalData = true
    let isReadOnly = true
    let summary = """
    Search the user's browsing history by words in the page title or URL and return matches with \
    dates, newest first. Use when the user asks about something they visited or read before ("that \
    article about…", "the site I was on yesterday"). Omit the query to get the most recent history. \
    Everything stays on this Mac.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Words to look for in page titles and URLs. Omit for the most recent history."],
            "max_results": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Optional. How many results to return (1–50). Default 10."]
        ]
    ]

    var outputSchema: [String: Any]? {
        PersonalDataSupport.listSchema([
            "title": ["type": "string"], "url": ["type": "string"], "visited": ["type": "string", "description": "ISO 8601 visit time."]
        ])
    }

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = PersonalDataSupport.maxResults(arguments, default: 10)

        let items = Array(browserState.history
            .filter { query.isEmpty || PersonalDataSupport.matches(query, in: "\($0.title) \($0.url)") }
            .sorted { $0.date > $1.date }
            .prefix(limit))

        let text: String
        if items.isEmpty {
            text = query.isEmpty ? "The browsing history is empty." : "No history entries match \"\(query)\"."
        } else {
            var lines = [query.isEmpty ? "Most recent history:" : "History entries matching \"\(query)\" (newest first):"]
            for (i, item) in items.enumerated() {
                lines.append("\(i + 1). \(item.title.isEmpty ? item.url : item.title)\n   \(item.url)\n   Visited \(PersonalDataSupport.relativeDate(item.date))")
            }
            text = lines.joined(separator: "\n")
        }
        let structured: [String: Any] = ["query": query, "count": items.count,
            "results": items.map { ["title": $0.title, "url": $0.url, "visited": PersonalDataSupport.iso.string(from: $0.date)] }]
        return .okStructured(text: text, structuredJSON: PersonalDataSupport.json(structured))
    }
}

// MARK: - search_bookmarks

@MainActor
struct SearchBookmarksTool: AgenticTool {
    let id = "search_bookmarks"
    let title = "Search bookmarks"
    let requiresPersonalData = true
    let isReadOnly = true
    let summary = """
    Search the user's bookmarks by words in the title, URL, or note and return matches, newest first. \
    Omit the query to get the most recent bookmarks. Everything stays on this Mac.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Words to look for in bookmark titles, URLs, and notes. Omit for the most recent bookmarks."],
            "max_results": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Optional. How many results to return (1–50). Default 10."]
        ]
    ]

    var outputSchema: [String: Any]? {
        PersonalDataSupport.listSchema([
            "title": ["type": "string"], "url": ["type": "string"],
            "note": ["type": "string"], "saved": ["type": "string", "description": "ISO 8601 save time."]
        ])
    }

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = PersonalDataSupport.maxResults(arguments, default: 10)

        let items = Array(browserState.bookmarks
            .filter { query.isEmpty || PersonalDataSupport.matches(query, in: "\($0.title) \($0.url) \($0.note ?? "")") }
            .sorted { $0.dateAdded > $1.dateAdded }
            .prefix(limit))

        let text: String
        if items.isEmpty {
            text = query.isEmpty ? "There are no bookmarks yet." : "No bookmarks match \"\(query)\"."
        } else {
            var lines = [query.isEmpty ? "Most recent bookmarks:" : "Bookmarks matching \"\(query)\" (newest first):"]
            for (i, item) in items.enumerated() {
                var block = "\(i + 1). \(item.title.isEmpty ? item.url : item.title)\n   \(item.url)"
                if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    block += "\n   Note: \(note)"
                }
                block += "\n   Saved \(PersonalDataSupport.relativeDate(item.dateAdded))"
                lines.append(block)
            }
            text = lines.joined(separator: "\n")
        }
        let structured: [String: Any] = ["query": query, "count": items.count,
            "results": items.map { item -> [String: Any] in
                ["title": item.title, "url": item.url, "note": item.note ?? "",
                 "saved": PersonalDataSupport.iso.string(from: item.dateAdded)]
            }]
        return .okStructured(text: text, structuredJSON: PersonalDataSupport.json(structured))
    }
}

// MARK: - add_bookmark

@MainActor
struct AddBookmarkTool: AgenticTool {
    let id = "add_bookmark"
    let title = "Save a bookmark"
    let requiresPersonalData = true
    let summary = """
    Save a URL to the user's bookmarks, with an optional title and note. Use when the user asks to \
    bookmark, save, or remember a page. If the same URL is already bookmarked it is updated, not \
    duplicated.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "The URL to bookmark. Accepts a bare domain (https is assumed)."],
            "title": ["type": "string", "description": "Optional. A title for the bookmark; the site's host is used if omitted."],
            "note": ["type": "string", "description": "Optional. A short note about why this was saved."]
        ],
        "required": ["url"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        guard var raw = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failed("Missing required argument 'url'.")
        }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.host != nil else {
            return .failed("'\(raw)' isn't a valid URL.")
        }
        let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = (arguments["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        browserState.bookmarkWithNote(url: url.absoluteString, title: title, note: note)
        let shown = title.isEmpty ? (url.host ?? url.absoluteString) : title
        return .ok("Saved bookmark: \(shown) — \(url.absoluteString)")
    }
}
