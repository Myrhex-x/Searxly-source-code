//
//  LocalAIChatSheet+CloudToolsExtended.swift
//  Searxly
//
//  The richer agentic tool surface for the Searxly AI (cloud 70B) path. These are intentionally
//  cloud-only: the on-device model keeps just web_search + open_website because of its ~4096-token
//  budget and the documented 6→2 tool-selection regression. The 70B handles a broad toolset reliably,
//  which is also what makes the paid agent meaningfully more capable than the free on-device one.
//
//  Every tool follows the same CloudTool contract as the canonical two (description for selection,
//  JSON-schema parameters, async @Sendable executor returning model text + optional clickable sources),
//  and binds to the live private closures wired in LocalAIChatView (BrowserState / SearXNG / wallet / Tor).
//
//  Tiers (per the product plan):
//    Tier 1 — search_history, search_bookmarks            (the user's own private data)
//    Tier 2 — fetch_url, deep_research, search_category, open_results_in_tabs
//    Tier 3 — knowledge_lookup, crypto_price, wallet_balance, privacy_status
//

import Foundation
import SwiftUI

/// Sendable snapshot of the live privacy posture, built on the main actor and read inside the
/// @Sendable tool executor (so it crosses the actor boundary safely as plain value types).
struct AIPrivacyStatusSnapshot: Sendable {
    let torEnabled: Bool
    let torRunning: Bool
    let vpnConnected: Bool
    let vpnHasActivePass: Bool
    let currentPageHost: String?
    let onionOfferHost: String?
    let onionOfferURL: String?
    let searxInstanceName: String
    let searxIsPrivate: Bool
}

/// Best-effort nudge so the user's local SearXNG is awake before a tool searches it. Mirrors the proven
/// DispatchQueue.main.async + Task dance used by the canonical web_search tool (avoids MainActor/Sendable
/// re-entrancy on the current Foundation Models toolchain). No-op for remote-only setups.
private func ensureLocalSearxngReady() async {
    DispatchQueue.main.async {
        Task {
            let mgr = LocalSearxngManager.shared
            if mgr.projectFolderExists {
                if await mgr.isLocalWebReady() {
                    await mgr.refreshStatus()
                } else {
                    await mgr.ensureReadyAndRunning()
                }
            }
        }
    }
    let isRunning = await MainActor.run { LocalSearxngManager.shared.status == .running }
    try? await Task.sleep(for: .milliseconds(isRunning ? 180 : 650))
}

extension LocalAIChatSheet {

    /// Builds the extended cloud tool set, sharing the same citation source box as the canonical tools
    /// so [n] numbering stays stable across every tool call in a turn.
    func makeExtendedCloudTools(sourceBox box: CloudSourceBox) -> [CloudTool] {
        // Capture closures locally (avoid capturing self in the @Sendable executors), matching the
        // pattern used for performPrivateSearch / openWebsite in makeCloudTools.
        let sh = self.searchHistory
        let sb = self.searchBookmarks
        let sc = self.searchByCategory
        let oit = self.openURLsInTabs
        let le = self.lookupEntity
        let pv = self.privacyStatusProvider
        let ps = self.performPrivateSearch

        // MARK: - Tier 1: personal data

        let searchHistoryTool = CloudTool(
            name: "search_history",
            description: "Search the user's OWN local browsing history (private, on their Mac). Use it whenever they refer to something they previously visited or read — 'that article I read about X', 'the GitHub page from last week', 'find where I saw Y', 'what was that site about Z'. Returns matching pages (title, URL, when visited), most recent first. This is private personal data, so only reach for it when the user is clearly asking about their own past browsing.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords to match against the user's history titles and URLs."]
                ],
                "required": ["query"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let search = sh, !q.isEmpty else {
                    return CloudToolOutput(modelText: "History search isn't available right now.")
                }
                let items = await search(q)
                guard !items.isEmpty else {
                    return CloudToolOutput(modelText: "No history entries match \"\(q)\". The user may have history disabled, or hasn't visited a matching page.")
                }
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let start = box.sources.count
                var lines = ["The user's matching history for \"\(q)\" (most recent first):"]
                for it in items {
                    let id = box.add(title: it.title, url: it.url, engine: "history")
                    lines.append("[\(id)] \(it.title)\nURL: \(it.url)\nVisited: \(formatter.string(from: it.date))")
                }
                return CloudToolOutput(modelText: lines.joined(separator: "\n\n"), sources: Array(box.sources[start...]))
            }
        )

        let searchBookmarksTool = CloudTool(
            name: "search_bookmarks",
            description: "Search the user's OWN saved bookmarks (including any notes they attached). Use for 'do I have a bookmark about X?', 'find my saved page on Y', 'that link I saved'. Returns matching bookmarks (title, URL, note). Private personal data — only use when the user is asking about their own saved pages.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords to match against the user's bookmark titles, URLs, and notes."]
                ],
                "required": ["query"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let search = sb, !q.isEmpty else {
                    return CloudToolOutput(modelText: "Bookmark search isn't available right now.")
                }
                let items = await search(q)
                guard !items.isEmpty else {
                    return CloudToolOutput(modelText: "No bookmarks match \"\(q)\".")
                }
                let start = box.sources.count
                var lines = ["The user's matching bookmarks for \"\(q)\":"]
                for it in items {
                    let id = box.add(title: it.title, url: it.url, engine: "bookmark")
                    var line = "[\(id)] \(it.title)\nURL: \(it.url)"
                    if let note = it.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        line += "\nNote: \(note)"
                    }
                    lines.append(line)
                }
                return CloudToolOutput(modelText: lines.joined(separator: "\n\n"), sources: Array(box.sources[start...]))
            }
        )

        // MARK: - Tier 2: research depth

        let fetchURLTool = CloudTool(
            name: "fetch_url",
            description: "Fetch and read the FULL readable text of one specific web page — going well beyond the short search snippet. Use to go deep on a URL you already have: a promising result from web_search/deep_research, or a link the user pasted. Returns the page's cleaned main text. Reach for it when a snippet isn't enough to answer accurately. Public http(s) pages only.",
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The absolute http(s) URL of the page to read in full."]
                ],
                "required": ["url"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let urlStr = (args["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !urlStr.isEmpty else {
                    return CloudToolOutput(modelText: "No URL was provided to fetch.")
                }
                guard let page = await WebPageFetcher.fetchReadable(urlString: urlStr) else {
                    return CloudToolOutput(modelText: "Couldn't read \"\(urlStr)\" — it may be blocked (internal/private host), not a readable web page, or unreachable.")
                }
                let start = box.sources.count
                let id = box.add(title: page.title, url: page.url, engine: "page")
                let text = "[\(id)] \(page.title)\nURL: \(page.url)\n\nReadable content:\n\(page.text)"
                return CloudToolOutput(modelText: text, sources: Array(box.sources[start...]))
            }
        )

        let deepResearchTool = CloudTool(
            name: "deep_research",
            description: "Do a deeper, multi-source pass when a single web_search isn't enough: it runs a private SearXNG search AND automatically reads the full text of the top few results, then hands you a rich, numbered source pack to synthesize a thorough, well-cited answer. Use for 'research…', 'give me a detailed/thorough breakdown of…', comparisons, or anything needing real depth. Slower than web_search — reserve it for genuinely involved questions.",
            parameters: [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "The research question or topic, in natural language."]
                ],
                "required": ["topic"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let topic = (args["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let searcher = ps, !topic.isEmpty else {
                    return CloudToolOutput(modelText: "Deep research isn't available right now.")
                }
                await ensureLocalSearxngReady()
                let results = await searcher(topic)
                guard !results.isEmpty else {
                    return CloudToolOutput(modelText: "No private search results for \"\(topic)\".")
                }

                let top = Array(results.prefix(6))
                let start = box.sources.count
                var urlToId: [String: Int] = [:]
                var blocks = ["Deep research pack for \"\(topic)\" — snippets first, then full text of the top sources:"]
                for r in top {
                    let id = box.add(title: r.title, url: r.url, engine: r.engine)
                    urlToId[r.url] = id
                    let snip = (r.content ?? "").prefix(200)
                    blocks.append("[\(id)] \(r.title)\nURL: \(r.url)\nSnippet: \(snip)")
                }

                // Read the top 3 in parallel for real depth (capped text each).
                let toFetch = top.prefix(3).map { $0.url }
                await withTaskGroup(of: (String, WebPageFetcher.FetchedPage?).self) { group in
                    for u in toFetch {
                        group.addTask { (u, await WebPageFetcher.fetchReadable(urlString: u, maxChars: 3_500)) }
                    }
                    for await (u, page) in group {
                        guard let page else { continue }
                        let id = urlToId[u] ?? box.add(title: page.title, url: page.url, engine: "page")
                        blocks.append("Full text of [\(id)] — \(page.title):\n\(page.text)")
                    }
                }

                return CloudToolOutput(modelText: blocks.joined(separator: "\n\n"), sources: Array(box.sources[start...]))
            }
        )

        let searchCategoryTool = CloudTool(
            name: "search_category",
            description: "Private SearXNG search restricted to a specific category. Use when the user clearly wants a particular kind of result: news (current events), images, videos, science (papers/academia), it (code/programming/tech), files, map (places), or music. For ordinary questions use web_search instead.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query."],
                    "category": [
                        "type": "string",
                        "enum": ["general", "news", "images", "videos", "science", "it", "files", "map", "music"],
                        "description": "Which SearXNG category to search."
                    ]
                ],
                "required": ["query", "category"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let cat = (args["category"] as? String ?? "general").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let searcher = sc, !q.isEmpty else {
                    return CloudToolOutput(modelText: "Category search isn't available right now.")
                }
                await ensureLocalSearxngReady()
                let results = await searcher(q, cat)
                guard !results.isEmpty else {
                    return CloudToolOutput(modelText: "No \(cat) results for \"\(q)\" from the user's private SearXNG.")
                }
                let start = box.sources.count
                var lines = ["Private \(cat) results for \"\(q)\":"]
                for r in results.prefix(8) {
                    let id = box.add(title: r.title, url: r.url, engine: r.engine)
                    var line = "[\(id)] \(r.title)\nURL: \(r.url)"
                    let snip = (r.content ?? "").prefix(180)
                    if !snip.isEmpty { line += "\nSnippet: \(snip)" }
                    lines.append(line)
                }
                return CloudToolOutput(modelText: lines.joined(separator: "\n\n"), sources: Array(box.sources[start...]))
            }
        )

        let openInTabsTool = CloudTool(
            name: "open_results_in_tabs",
            description: "Open several specific web pages as new browser tabs at once. Use ONLY when the user explicitly asks to open/pull up multiple pages ('open the top 3', 'open these in tabs', 'pull those up'). Pass the exact URLs (e.g. ones you got from a prior web_search or deep_research). Do NOT use for a single navigation (use open_website) or for answering a question.",
            parameters: [
                "type": "object",
                "properties": [
                    "urls": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Up to 5 absolute http(s) URLs to open as tabs."
                    ]
                ],
                "required": ["urls"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let raw = (args["urls"] as? [String]) ?? (args["urls"] as? [Any])?.compactMap { $0 as? String } ?? []
                let urls = raw
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("http") }
                guard let opener = oit, !urls.isEmpty else {
                    return CloudToolOutput(modelText: "No valid URLs were provided to open.")
                }
                let capped = Array(urls.prefix(5))
                await MainActor.run { opener(capped) }
                return CloudToolOutput(modelText: "Opened \(capped.count) page(s) in new tabs: \(capped.joined(separator: ", ")).")
            }
        )

        // MARK: - Tier 3: Searxly-native

        let knowledgeTool = CloudTool(
            name: "knowledge_lookup",
            description: "Get a structured fact card for a well-known entity (person, company, place, product, etc.) from the private knowledge panel (Grokipedia + official-site database). Returns a clean summary, key facts, and the official site. A fast, structured grounding for 'who/what is X' — often better than a broad web_search for a single named entity.",
            parameters: [
                "type": "object",
                "properties": [
                    "entity": ["type": "string", "description": "The entity to look up, e.g. 'Tesla', 'Elon Musk', 'Apple Inc'."]
                ],
                "required": ["entity"]
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let entity = (args["entity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lookup = le, !entity.isEmpty else {
                    return CloudToolOutput(modelText: "Knowledge lookup isn't available right now.")
                }
                guard let content = await lookup(entity), case let .entity(data) = content.kind else {
                    return CloudToolOutput(modelText: "No knowledge card found for \"\(entity)\". Use web_search instead.")
                }
                let start = box.sources.count
                var lines = ["Knowledge card for \(data.title):"]
                if !data.aboutParagraphs.isEmpty {
                    lines.append(data.aboutParagraphs.prefix(3).joined(separator: "\n\n"))
                }
                if !data.facts.isEmpty {
                    var factLines = ["Key facts:"]
                    for f in data.facts.prefix(10) { factLines.append("- \(f.label): \(f.value)") }
                    lines.append(factLines.joined(separator: "\n"))
                }
                if let site = data.officialSiteURL, !site.isEmpty {
                    box.add(title: data.officialSiteLabel ?? "\(data.title) — official site", url: site, engine: "official")
                    lines.append("Official site: \(site)")
                }
                if let grok = data.grokipediaURL, !grok.isEmpty {
                    box.add(title: "\(data.title) — Grokipedia", url: grok, engine: "grokipedia")
                    lines.append("Reference: \(grok)")
                }
                return CloudToolOutput(modelText: lines.joined(separator: "\n\n"), sources: Array(box.sources[start...]))
            }
        )

        let cryptoPriceTool = CloudTool(
            name: "crypto_price",
            description: "Get live crypto prices the user's in-app wallet already tracks (ETH, $SEARXLY, and their Base tokens) and optionally convert an amount between two of them at the current USD rate. READ-ONLY — it never moves funds or places a trade. Use for 'what's ETH at?', 'price of SEARXLY', 'how much is 0.5 ETH in USDC?'.",
            parameters: [
                "type": "object",
                "properties": [
                    "symbol": ["type": "string", "description": "Optional. A token symbol to focus on, e.g. 'ETH', 'SEARXLY', 'USDC'. Omit to list the main prices."],
                    "amount": ["type": "number", "description": "Optional. Amount to convert (requires symbol + to_symbol)."],
                    "to_symbol": ["type": "string", "description": "Optional. Convert 'amount' of 'symbol' into this token at current USD prices."]
                ],
                "required": [String]()
            ],
            execute: { @Sendable args async -> CloudToolOutput in
                let symbol = (args["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let toSymbol = (args["to_symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let amount = (args["amount"] as? Double)
                    ?? (args["amount"] as? Int).map(Double.init)
                    ?? (args["amount"] as? NSNumber)?.doubleValue
                let text = await MainActor.run { () -> String in
                    let wm = WalletManager.shared
                    // A closure (not a nested func) so it inherits this block's main-actor isolation
                    // and can read the @MainActor wallet state.
                    let price: (String) -> Double? = { sym in
                        if sym == "ETH" || sym == "WETH" { return wm.ethPriceUSD > 0 ? wm.ethPriceUSD : nil }
                        if sym == "SEARXLY" { return wm.searxlyPriceUSD > 0 ? wm.searxlyPriceUSD : nil }
                        if let t = wm.tokens.first(where: { $0.symbol.uppercased() == sym }), t.priceUSD > 0 { return t.priceUSD }
                        if sym == "USDC" || sym == "USDT" || sym == "DAI" { return 1.0 }
                        return nil
                    }
                    if let s = symbol, let to = toSymbol, let amt = amount,
                       let p1 = price(s), let p2 = price(to), p2 > 0 {
                        let out = amt * p1 / p2
                        return "\(formatAmount(amt)) \(s) ≈ \(formatAmount(out)) \(to) at current prices (\(s) = \(wm.formatFiatPrice(p1)), \(to) = \(wm.formatFiatPrice(p2))). Read-only estimate, not an executable swap quote."
                    }
                    if let s = symbol {
                        guard let p = price(s) else {
                            return "I don't have a live price for \(s) loaded yet. Opening the Wallet once refreshes prices."
                        }
                        return "\(s) is \(wm.formatFiatPrice(p)) right now."
                    }
                    var parts: [String] = []
                    if wm.ethPriceUSD > 0 { parts.append("ETH \(wm.formatFiatPrice(wm.ethPriceUSD))") }
                    if wm.searxlyPriceUSD > 0 { parts.append("SEARXLY \(wm.formatFiatPrice(wm.searxlyPriceUSD))") }
                    for t in wm.visibleTokens where t.priceUSD > 0 && t.symbol.uppercased() != "ETH" && t.symbol.uppercased() != "SEARXLY" {
                        parts.append("\(t.symbol) \(wm.formatFiatPrice(t.priceUSD))")
                    }
                    if parts.isEmpty { return "No live prices are loaded yet. Opening the Wallet once fetches them." }
                    return "Current prices — " + parts.joined(separator: ", ") + "."
                }
                return CloudToolOutput(modelText: text)
            }
        )

        let walletBalanceTool = CloudTool(
            name: "wallet_balance",
            description: "Report the balances currently held in the user's in-app Searxly wallet (token amounts + USD value + total). READ-ONLY — it cannot send, swap, or move anything. Use for 'what's in my wallet?', 'how much ETH do I have?', 'my balance'. This surfaces the user's own financial holdings, so only use it when they ask about their wallet.",
            parameters: [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ],
            execute: { @Sendable _ async -> CloudToolOutput in
                let text = await MainActor.run { () -> String in
                    let wm = WalletManager.shared
                    guard wm.activeAccount != nil else {
                        return "No wallet is set up yet. The user can create or import one in the Wallet."
                    }
                    let held = wm.visibleTokens.filter { $0.balance > 0 }
                    guard !held.isEmpty else {
                        return "The wallet is set up but shows no token balances right now (it may be locked, empty, or balances haven't refreshed — opening the Wallet refreshes them)."
                    }
                    var lines = ["Current wallet holdings:"]
                    for t in held.sorted(by: { $0.usdValue > $1.usdValue }) {
                        lines.append("- \(t.formattedBalance) \(t.symbol) (\(t.formattedUSD))")
                    }
                    lines.append("Total: \(wm.formatFiatPrice(wm.totalPortfolioUSD)).")
                    return lines.joined(separator: "\n")
                }
                return CloudToolOutput(modelText: text)
            }
        )

        let privacyTool = CloudTool(
            name: "privacy_status",
            description: "Report the user's live privacy posture: whether Tor is on/connected, whether the Searxly VPN is connected, whether the current page has a .onion mirror available, and whether their search instance is private. READ-ONLY. Use for 'am I private/anonymous right now?', 'is Tor on?', 'is there an onion version of this site?'.",
            parameters: [
                "type": "object",
                "properties": [String: Any](),
                "required": [String]()
            ],
            execute: { @Sendable _ async -> CloudToolOutput in
                guard let provider = pv else {
                    return CloudToolOutput(modelText: "Privacy status isn't available right now.")
                }
                let s = await provider()
                var lines = ["Live privacy status:"]
                lines.append("- Tor: \(s.torEnabled ? (s.torRunning ? "ON and connected" : "enabled, connecting…") : "off")")
                lines.append("- Searxly VPN: \(s.vpnConnected ? "connected" : (s.vpnHasActivePass ? "off (an active pass is available)" : "off"))")
                lines.append("- Search instance: \(s.searxInstanceName) (\(s.searxIsPrivate ? "private / self-hosted" : "public"))")
                if let host = s.onionOfferHost, let onion = s.onionOfferURL {
                    lines.append("- This page (\(host)) offers a .onion mirror: \(onion)")
                } else if let page = s.currentPageHost {
                    lines.append("- The current page (\(page)) doesn't advertise a .onion mirror.")
                }
                return CloudToolOutput(modelText: lines.joined(separator: "\n"))
            }
        )

        return [
            searchHistoryTool, searchBookmarksTool,
            fetchURLTool, deepResearchTool, searchCategoryTool, openInTabsTool,
            knowledgeTool, cryptoPriceTool, walletBalanceTool, privacyTool
        ]
    }
}

/// Compact number formatting for crypto amounts (trim trailing zeros, avoid scientific notation noise).
private func formatAmount(_ value: Double) -> String {
    if value == 0 { return "0" }
    let abs = Swift.abs(value)
    let digits = abs < 1 ? 6 : (abs < 1_000 ? 4 : 2)
    let s = String(format: "%.\(digits)f", value)
    // Trim trailing zeros and any dangling decimal point.
    if s.contains(".") {
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
    return s
}
