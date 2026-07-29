//
//  ReadPageTool.swift
//  Searxly — Agentic Tools
//
//  `read_page` — fetch the readable text of one web page. Wraps the SSRF-guarded, Tor-aware
//  WebPageFetcher, so a local model can go beyond a search snippet without any request touching an
//  internal/loopback address or leaking through the wrong network lane.
//

import Foundation

@MainActor
struct ReadPageTool: AgenticTool {
    let id = "read_page"
    let title = "Read a page"
    let isReadOnly = true

    /// Characters returned per call. Long pages continue via `start_index`.
    private static let chunkChars = 6_000
    private static let maxStartIndex = 200_000

    let summary = """
    Fetch and return the readable text of a single web page by URL. Use to read an article or a search \
    result in full (beyond its snippet). Long pages are returned in chunks — if the result says it was \
    truncated, call again with the suggested start_index to keep reading. The fetch is anonymous, rides \
    Tor in Maximum Privacy, and is guarded against local/internal addresses.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "Full http(s) URL of the page to read."],
            "start_index": [
                "type": "integer",
                "minimum": 0,
                "description": "Optional. Character offset to continue reading a long page from (use the value suggested by a previous truncated result). Default 0."
            ]
        ],
        "required": ["url"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let url = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return .failed("Missing required argument 'url'.")
        }
        let start = min(max(AgenticToolFormat.intArg(arguments["start_index"]) ?? 0, 0), Self.maxStartIndex)

        guard let page = await WebPageFetcher.fetchReadable(urlString: url, maxChars: start + Self.chunkChars) else {
            return .failed("Couldn't read that page — it may be blocked, non-HTML, or unreachable.")
        }
        guard start < page.text.count else {
            return .failed("start_index \(start) is past the end — the page has only \(page.text.count) characters of readable text.")
        }

        var out = "Title: \(page.title)\nURL: \(page.url)\n"
        if start > 0 { out += "(continuing from character \(start))\n" }
        out += "\n" + String(page.text.dropFirst(start))

        // Hitting the fetch cap exactly means there is (very likely) more page to read.
        if page.text.count == start + Self.chunkChars {
            out += "\n\n[Truncated. Call read_page again with start_index=\(page.text.count) to continue reading.]"
        }
        return .ok(out)
    }
}
