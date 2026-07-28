//
//  AIToolCatalog.swift
//  Searxly
//
//  Single source of truth for the user-facing agent tool list: a stable id (which MUST match the
//  CloudTool.name / FoundationModels Tool.name), display metadata, and the tier it belongs to.
//
//  Used by:
//   - the "Available Tools" popup in the chat (ToolsListSheet)
//   - Searxly AI settings (per-tool on/off toggles)
//   - the enable filter applied when assembling the cloud + on-device tool sets
//
//  Per-tool enable state is persisted as AIPreferences.disabledToolIDs (default empty = everything on,
//  so newly shipped tools are opt-out, not opt-in).
//

import Foundation

struct AIToolInfo: Identifiable, Hashable {
    /// Stable tool id — MUST equal the tool's `name` in the cloud/on-device definitions.
    let id: String
    let icon: String          // SF Symbol (rendered monochrome, per brand)
    let name: String          // display name
    let summary: String       // one-line description for the list
    let example: String       // short "e.g. …" usage hint
    let tier: Tier
    /// Tools the on-device model also receives. Everything else is cloud-only (Searxly AI 70B).
    let availableOnDevice: Bool

    enum Tier: String, CaseIterable, Identifiable {
        case core = "Core"
        case personal = "Your data"
        case research = "Research"
        case searxly = "Searxly tools"
        var id: String { rawValue }
    }
}

enum AIToolCatalog {

    /// Every tool the assistant can use, in display order. Ids match the tool definitions exactly.
    static let all: [AIToolInfo] = [
        // Core (also available to the on-device model)
        AIToolInfo(id: "web_search", icon: "magnifyingglass", name: "Web search",
                   summary: "Searches the web using only your private/local SearXNG. Results are synthesized into an answer that stays in the chat.",
                   example: "e.g. “who is Elon Musk?” or “latest iPhone”",
                   tier: .core, availableOnDevice: true),
        AIToolInfo(id: "open_website", icon: "globe", name: "Open website",
                   summary: "Finds the official (or best) site for a brand/service via your private SearXNG and opens it in a new tab. Explicit navigation only.",
                   example: "e.g. “open the official Tesla site” or “go to x.com”",
                   tier: .core, availableOnDevice: true),

        // Your data (private, on your Mac)
        AIToolInfo(id: "search_history", icon: "clock.arrow.circlepath", name: "Search history",
                   summary: "Looks through your own browsing history to find a page you visited before.",
                   example: "e.g. “that article I read about Rust last week”",
                   tier: .personal, availableOnDevice: false),
        AIToolInfo(id: "search_bookmarks", icon: "bookmark", name: "Search bookmarks",
                   summary: "Searches your saved bookmarks and their notes.",
                   example: "e.g. “do I have a bookmark about async Swift?”",
                   tier: .personal, availableOnDevice: false),

        // Research depth
        AIToolInfo(id: "fetch_url", icon: "doc.text.magnifyingglass", name: "Read page",
                   summary: "Reads the full text of one specific page (beyond the search snippet) so answers can be more accurate.",
                   example: "e.g. “read this link and summarize it”",
                   tier: .research, availableOnDevice: false),
        AIToolInfo(id: "deep_research", icon: "books.vertical", name: "Deep research",
                   summary: "A thorough pass: searches your SearXNG and auto-reads the top results, then writes a detailed, well-cited answer.",
                   example: "e.g. “give me a detailed breakdown of …”",
                   tier: .research, availableOnDevice: false),
        AIToolInfo(id: "search_category", icon: "square.grid.2x2", name: "Category search",
                   summary: "A private search limited to a category: news, images, videos, science, code, files, maps, or music.",
                   example: "e.g. “latest news on …” or “images of …”",
                   tier: .research, availableOnDevice: false),
        AIToolInfo(id: "open_results_in_tabs", icon: "rectangle.stack", name: "Open in tabs",
                   summary: "Opens several pages at once as new tabs. Only when you explicitly ask to pull multiple pages up.",
                   example: "e.g. “open the top 3 results in tabs”",
                   tier: .research, availableOnDevice: false),

        // Searxly-native
        AIToolInfo(id: "knowledge_lookup", icon: "info.circle", name: "Knowledge lookup",
                   summary: "Gets a structured fact card (summary, key facts, official site) for a well-known person, company, or place.",
                   example: "e.g. “what is Tesla?” as a quick fact card",
                   tier: .searxly, availableOnDevice: false),
        AIToolInfo(id: "crypto_price", icon: "chart.line.uptrend.xyaxis", name: "Crypto prices",
                   summary: "Live prices your wallet tracks (ETH and your tokens) and simple conversions. Read-only — never moves funds.",
                   example: "e.g. “what's ETH at?” or “0.5 ETH in USDC”",
                   tier: .searxly, availableOnDevice: false),
        AIToolInfo(id: "wallet_balance", icon: "wallet.pass", name: "Wallet balance",
                   summary: "Reports what's in your in-app wallet (amounts + USD + total). Read-only — it can't send or swap anything.",
                   example: "e.g. “what's in my wallet?”",
                   tier: .searxly, availableOnDevice: false),
        AIToolInfo(id: "privacy_status", icon: "lock.shield", name: "Privacy status",
                   summary: "Reports your live Tor / VPN / onion-mirror / search-instance posture.",
                   example: "e.g. “am I private right now?” or “is Tor on?”",
                   tier: .searxly, availableOnDevice: false)
    ]

    /// Tools grouped by tier, preserving declaration order, skipping empty tiers.
    static var byTier: [(tier: AIToolInfo.Tier, tools: [AIToolInfo])] {
        AIToolInfo.Tier.allCases.compactMap { tier in
            let tools = all.filter { $0.tier == tier }
            return tools.isEmpty ? nil : (tier, tools)
        }
    }
}
