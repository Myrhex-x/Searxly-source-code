//
//  ReadCurrentPageTool.swift
//  Searxly — Agentic Tools
//
//  `read_current_page` — the readable text of the tab the user is looking at RIGHT NOW, so a local
//  model can answer "summarize this page" / "what does this article say?" without a second fetch
//  (which would miss logged-in or dynamically rendered content). Browser-control tier: it exposes
//  the live session. Text is sliced in-page (so huge pages never cross the JS bridge whole) and run
//  through PageContentGuard so prompt-injection markers in the page can't hijack the model.
//
//  SSRF NOTE (deliberate asymmetry vs. read_page): read_page fetches an arbitrary URL and so runs the
//  full SSRF guard (no localhost/private/internal hosts). This tool reads only what is ALREADY loaded
//  in the user's own active tab — a page the user themselves navigated to and is looking at — so it
//  carries no URL argument and no SSRF guard. It cannot be steered to a new address; it reflects the
//  user's current view. If a future caller lets the model pick which tab/URL to read, re-introduce the
//  guard there.
//

import Foundation
import WebKit

/// Shared chunked-reading of a web view's readable text — used by read_current_page and read_tab.
/// Reads `document.body.innerText` sliced in-page (so a huge page never crosses the JS bridge whole),
/// sanitizes it through PageContentGuard, and formats a chunk with a continuation hint.
@MainActor
enum ReadableText {
    static let chunkChars = 8_000
    static let maxStartIndex = 500_000

    static func read(_ wv: WKWebView, start rawStart: Int, continueTool: String) async -> AgenticToolOutcome {
        let start = min(max(rawStart, 0), maxStartIndex)
        let js = "(function(){var t=document.body?document.body.innerText:'';return JSON.stringify({len:t.length,title:document.title,url:location.href,text:t.slice(\(start),\(start + chunkChars))});})();"
        guard let raw = (try? await wv.evaluateJavaScript(js)) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Couldn't read the page.")
        }
        let total = AgenticToolFormat.intArg(obj["len"]) ?? 0
        let title = (obj["title"] as? String) ?? ""
        let url = (obj["url"] as? String) ?? ""
        let text = PageContentGuard.sanitize((obj["text"] as? String) ?? "", limit: chunkChars)

        guard total > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("The page has no readable text (it may still be loading).")
        }
        guard start < total else {
            return .failed("start_index \(start) is past the end — the page has \(total) characters of readable text.")
        }

        var out = "Title: \(title)\nURL: \(url)\n"
        if start > 0 { out += "(continuing from character \(start))\n" }
        out += "\n" + text
        let end = start + chunkChars
        if end < total {
            out += "\n\n[Truncated at character \(end) of \(total). Call \(continueTool) again with start_index=\(end) to continue.]"
        }
        return .ok(out)
    }
}

@MainActor
struct ReadCurrentPageTool: AgenticTool {
    let id = "read_current_page"
    let title = "Read the current page"
    let requiresBrowserControl = true
    let isReadOnly = true

    let summary = """
    Return the readable text of the tab the user is currently viewing — including logged-in or \
    dynamically loaded content that read_page can't fetch. Use for "summarize this page" or questions \
    about what's on screen. Long pages are returned in chunks — if the result says it was truncated, \
    call again with the suggested start_index.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "start_index": [
                "type": "integer",
                "minimum": 0,
                "description": "Optional. Character offset to continue reading a long page from (use the value suggested by a previous truncated result). Default 0."
            ]
        ]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let wv = BrowserActions.activeWebView() else { return .failed("No active browser tab.") }
        return await ReadableText.read(wv, start: AgenticToolFormat.intArg(arguments["start_index"]) ?? 0,
                                       continueTool: "read_current_page")
    }
}
