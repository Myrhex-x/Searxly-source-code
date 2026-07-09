//
//  OpenWebsiteTool.swift
//  Searxly — Agentic Tools
//
//  `open_website` — the one browser-control tool: opens a site in a new Searxly tab. Unlike the
//  read-only web tools, this changes what the user sees on screen, so it's for explicit navigation
//  only. Resolution is private (OfficialEntityDatabase + SiteResolver + the user's SearXNG).
//

import Foundation

@MainActor
struct OpenWebsiteTool: AgenticTool {
    let id = "open_website"
    let summary = """
    Open a website in the user's Searxly browser as a new tab. Use ONLY for explicit navigation \
    ("open the official Tesla site", "go to x.com", "show me the Wikipedia page for …"). Pass a clean \
    site name/brand or a URL; Searxly resolves the best/official page privately via the user's own \
    SearXNG. This changes what the user sees on screen, so don't use it for information lookups — use \
    web_search for those.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "A site name/brand (e.g. 'Tesla', 'xAI') or a URL to open."]
        ],
        "required": ["query"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failed("Missing required argument 'query'.")
        }
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        // Switch to web content and hand off to the private site resolver (same path the browser uses).
        browserState.clearNativeSearch()
        browserState.showingWebContent = true
        browserState.openWebsite(description: query)
        return .ok("Opening \"\(query)\" in a new Searxly tab (resolved privately).")
    }
}
