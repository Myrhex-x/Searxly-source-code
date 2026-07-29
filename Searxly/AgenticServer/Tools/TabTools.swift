//
//  TabTools.swift
//  Searxly — Agentic Tools
//
//  Tab management for the browser-control tier: list the user's open tabs, switch between them,
//  open URLs in new tabs, and close a tab. Privacy rule: ONLY standard web tabs are ever exposed —
//  private and onion tabs are invisible to the model (they don't appear in list_tabs, can't be
//  switched to, and can't be closed), and utility tabs (passwords vault etc.) are likewise hidden.
//
//  Tabs are addressed by their 1-based position in the most recent list_tabs output. Positions shift
//  when tabs open or close, so tools tell the model to re-list after any change.
//

import Foundation
import WebKit

@MainActor
enum TabToolSupport {
    /// The tabs the model may see and act on: standard (non-private, non-onion) web tabs only.
    static func exposedTabs(_ browserState: BrowserState) -> [BrowserTab] {
        browserState.tabs.filter { $0.kind == .web && $0.privacyMode == .standard }
    }

    static func describe(_ tab: BrowserTab, isActive: Bool) -> String {
        let url = tab.currentURL?.absoluteString ?? "(empty tab)"
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(title.isEmpty ? "Untitled" : title) — \(url)\(isActive ? "  (active)" : "")"
    }

    /// Resolve a 1-based tab number from list_tabs into a live tab.
    static func tab(at number: Int, in browserState: BrowserState) -> BrowserTab? {
        let exposed = exposedTabs(browserState)
        guard number >= 1, number <= exposed.count else { return nil }
        return exposed[number - 1]
    }
}

// MARK: - list_tabs

@MainActor
struct ListTabsTool: AgenticTool {
    let id = "list_tabs"
    let title = "List tabs"
    let requiresBrowserControl = true
    let isReadOnly = true
    let summary = "List the user's open browser tabs with their titles and URLs, numbered for use with switch_tab / close_tab. Private tabs are never shown. Re-list after opening or closing tabs — numbers shift."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        let exposed = TabToolSupport.exposedTabs(browserState)
        guard !exposed.isEmpty else {
            return .ok("No open tabs (private tabs, if any, are not shown).")
        }
        var lines = ["Open tabs (use the number with switch_tab / close_tab):"]
        for (i, tab) in exposed.enumerated() {
            lines.append("\(i + 1). \(TabToolSupport.describe(tab, isActive: tab.id == browserState.selectedTabID))")
        }
        let hiddenCount = browserState.tabs.filter { $0.kind == .web && $0.privacyMode != .standard }.count
        if hiddenCount > 0 {
            lines.append("(\(hiddenCount) private tab\(hiddenCount == 1 ? "" : "s") not shown)")
        }
        return .ok(lines.joined(separator: "\n"))
    }
}

// MARK: - read_tab

@MainActor
struct ReadTabTool: AgenticTool {
    let id = "read_tab"
    let title = "Read a background tab"
    let requiresBrowserControl = true
    let isReadOnly = true
    let summary = "Return the readable text of an open tab by its number from list_tabs WITHOUT switching to it — use to compare or pull from several pages at once. Long tabs come in chunks; continue with start_index. Private tabs are never readable."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "tab": ["type": "integer", "description": "The tab number from list_tabs."],
            "start_index": ["type": "integer", "minimum": 0, "description": "Optional. Character offset to continue a long tab from. Default 0."]
        ],
        "required": ["tab"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        guard let number = AgenticToolFormat.intArg(arguments["tab"]) else {
            return .failed("Missing integer 'tab'.")
        }
        guard let tab = TabToolSupport.tab(at: number, in: browserState) else {
            return .failed("No tab \(number) — run list_tabs to see the current numbers.")
        }
        // A backgrounded tab may be hibernated (no web view). Wake it so it can be read; this reloads
        // the tab's page in the background but doesn't switch the user to it.
        if tab.webView == nil { tab.wakeUp() }
        guard let wv = tab.webView else {
            return .failed("Tab \(number) isn't loaded yet — try again in a moment, or switch_tab to it then use read_current_page.")
        }
        // A woken or still-loading tab reports empty text until it finishes; poll until it's readable
        // instead of guessing a fixed delay. An already-loaded tab passes on the first check.
        await Self.waitUntilReadable(wv)
        return await ReadableText.read(wv, start: AgenticToolFormat.intArg(arguments["start_index"]) ?? 0,
                                       continueTool: "read_tab")
    }

    /// Poll until the tab has finished loading and has visible text, up to ~4s. Cheap when the tab is
    /// already loaded (the first check returns immediately); rescues a heavy or just-woken tab that
    /// would otherwise read as empty.
    private static func waitUntilReadable(_ wv: WKWebView) async {
        for _ in 0..<20 {
            let ready = ((try? await wv.evaluateJavaScript("document.readyState")) as? String) == "complete"
            let hasText = (((try? await wv.evaluateJavaScript("document.body ? document.body.innerText.length : 0")) as? NSNumber)?.intValue ?? 0) > 0
            if ready && hasText { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

// MARK: - switch_tab

@MainActor
struct SwitchTabTool: AgenticTool {
    let id = "switch_tab"
    let title = "Switch tab"
    let requiresBrowserControl = true
    let summary = "Switch the browser to another open tab by its number from list_tabs."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["tab": ["type": "integer", "description": "The tab number from list_tabs."]],
        "required": ["tab"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        guard let number = AgenticToolFormat.intArg(arguments["tab"]) else {
            return .failed("Missing integer 'tab'.")
        }
        guard let tab = TabToolSupport.tab(at: number, in: browserState) else {
            return .failed("No tab \(number) — run list_tabs to see the current numbers.")
        }
        browserState.selectedTabID = tab.id
        browserState.showingWebContent = true
        tab.wakeUp()
        return .ok("Switched to tab \(number): \(TabToolSupport.describe(tab, isActive: true))")
    }
}

// MARK: - open_tab

@MainActor
struct OpenTabTool: AgenticTool {
    let id = "open_tab"
    let title = "Open tabs"
    let requiresBrowserControl = true
    let summary = "Open one or more URLs, each in a new browser tab. The first opened tab becomes active unless background=true. Accepts full URLs or bare domains (https is assumed)."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "urls": [
                "type": "array",
                "items": ["type": "string"],
                "minItems": 1,
                "maxItems": 10,
                "description": "The URLs (or domains) to open, one tab each. Up to 10."
            ],
            "background": [
                "type": "boolean",
                "description": "Open without switching to the new tab. Default false (the first opened tab becomes active)."
            ]
        ],
        "required": ["urls"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        // Accept both an array and a single string (small models sometimes send one URL directly).
        let rawList: [String]
        if let array = arguments["urls"] as? [String] {
            rawList = array
        } else if let single = arguments["urls"] as? String {
            rawList = [single]
        } else {
            return .failed("Missing 'urls' (an array of URLs).")
        }
        let background = (arguments["background"] as? Bool) ?? false

        var opened: [String] = []
        var firstOpenedID: UUID?
        for raw in rawList.prefix(10) {
            var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            if !candidate.hasPrefix("http://") && !candidate.hasPrefix("https://") { candidate = "https://" + candidate }
            guard let url = URL(string: candidate), url.host != nil else { continue }

            let before = Set(browserState.tabs.map(\.id))
            browserState.openURLInBackgroundTab(url)
            if firstOpenedID == nil {
                firstOpenedID = browserState.tabs.first(where: { !before.contains($0.id) })?.id
            }
            opened.append(url.absoluteString)
        }
        guard !opened.isEmpty else {
            return .failed("None of the given URLs were valid.")
        }
        if !background, let id = firstOpenedID {
            browserState.selectedTabID = id
            browserState.showingWebContent = true
        }
        let list = opened.map { "- \($0)" }.joined(separator: "\n")
        return .ok("Opened \(opened.count) tab\(opened.count == 1 ? "" : "s"):\n\(list)\nTab numbers have changed — run list_tabs before switching or closing by number.")
    }
}

// MARK: - close_tab

@MainActor
struct CloseTabTool: AgenticTool {
    let id = "close_tab"
    let title = "Close tab"
    let requiresBrowserControl = true
    let summary = "Close an open tab by its number from list_tabs. The user can reopen it with Reopen Closed Tab, but only close tabs when clearly asked to."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["tab": ["type": "integer", "description": "The tab number from list_tabs."]],
        "required": ["tab"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Searxly isn't ready yet — try again in a moment.")
        }
        guard let number = AgenticToolFormat.intArg(arguments["tab"]) else {
            return .failed("Missing integer 'tab'.")
        }
        guard let tab = TabToolSupport.tab(at: number, in: browserState) else {
            return .failed("No tab \(number) — run list_tabs to see the current numbers.")
        }
        let description = TabToolSupport.describe(tab, isActive: false)
        browserState.closeTab(tab)
        return .ok("Closed tab \(number): \(description)\nTab numbers have changed — run list_tabs before acting on another tab.")
    }
}
