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
    let summary = """
    Fetch and return the readable text of a single web page by URL. Use to read an article or a search \
    result in full (beyond its snippet). The fetch is anonymous, rides Tor in Maximum Privacy, and is \
    guarded against local/internal addresses.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "Full http(s) URL of the page to read."]
        ],
        "required": ["url"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let url = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return .failed("Missing required argument 'url'.")
        }
        guard let page = await WebPageFetcher.fetchReadable(urlString: url, maxChars: 6_000) else {
            return .failed("Couldn't read that page — it may be blocked, non-HTML, or unreachable.")
        }
        return .ok("Title: \(page.title)\nURL: \(page.url)\n\n\(page.text)")
    }
}
