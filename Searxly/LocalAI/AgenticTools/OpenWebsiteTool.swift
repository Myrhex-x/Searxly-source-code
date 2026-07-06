//
//  OpenWebsiteTool.swift
//  Searxly
//
//  One of the two canonical work tools for the Local AI on-device system (post 2026-06 minimal-tool rework).
//
//  Purpose:
//  - The ONLY navigation / browser side-effect tool.
//  - Strictly for explicit user commands to load and view a page in the browser
//    ("open tesla's official website for me", "go to x.com", "visit the Apple site", "show me the Wikipedia page for X").
//  - Resolves safely (fast direct URL if it looks like a domain, otherwise private "official X site" search via the user's SearXNG).
//  - Performs the actual tab open via the host closure (BrowserState).
//  - The chat sheet is dismissed after the action; no follow-up synthesis in the (now-closed) chat is required.
//  - The model must NEVER choose this for informational / "tell me who / what is" queries — those must use WebSearchTool so the answer stays in-chat.
//
//  This file owns the native Tool definition, marker names, confirmation details, and any small helpers
//  specific to open_website so the behavior is isolated and easy to debug/fix later.

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Native Foundation Models Tool Support (when toolsEnabled)

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
struct OpenWebsiteArgs {
    @Guide(description: "Clean, concise name or brand for the site to open (e.g. 'Tesla', 'x.com', 'Apple developer', 'Elon Musk Terafab chip facility', 'xAI Memphis', 'Neuralink', 'terafab'). For the platform formerly known as Twitter ALWAYS use 'x.com' or 'X'. Extract the core entity from the user's request and omit filler like 'official ... website' or full sentences. The host (OfficialEntityDatabase + SiteResolver) will resolve it privately to the best matching official page (terafab → https://terafab.ai, xAI facilities, etc.).")
    var description: String
}

@available(macOS 26.0, *)
struct OpenWebsiteTool: Tool {
    let name = "open_website"
    let description = "Open a website in the user's browser as a new tab. Use this ONLY for explicit navigation commands (examples: 'open the official Tesla site for me', 'go to x.com', 'visit the Wikipedia page', 'show me the Apple developer page', 'open elon musk chip facility', 'open terafab', 'go to xAI Memphis'). For X (the platform) always pass 'x.com'. Pass a clean entity name (e.g. 'Tesla', 'xAI', 'Elon Musk Terafab', 'terafab'). The host (OfficialEntityDatabase + SiteResolver + private SearXNG) will resolve safely using a rich trusted local map first (terafab → https://terafab.ai) then relevance + conservative safety checks (Apple-style: no sensitive/adult/scam content, high grounding required). NEVER use for information-seeking or descriptive queries such as 'who is Elon Musk?', 'what is his chip facility?', 'tell me about the Terafab', or 'can you open elon musk official chip facility website' — those are web_search + answer-in-chat cases. The classification gate in the system rules takes precedence."

    typealias Arguments = OpenWebsiteArgs

    private let execute: @Sendable (String) async -> String
    private let logUse: (@Sendable (String, String) -> Void)?

    init(execute: @escaping @Sendable (String) async -> String, logUse: (@Sendable (String, String) -> Void)? = nil) {
        self.execute = execute
        self.logUse = logUse
    }

    func call(arguments: Arguments) async throws -> String {
        logUse?("open_website", arguments.description)
        return await execute(arguments.description)
    }
}

#endif

// MARK: - User-called / explicit navigation support

enum OpenWebsite {

    /// The canonical name used in legacy TOOL_REQUEST: markers and bare-tool detection.
    static let markerName = "open_website"

    /// Trigger the host-side open (the real work — resolution + tab creation — lives in the
    /// BrowserState closure passed at wiring time). Returns a short status string for logging / any
    /// post-execution note (the normal path dismisses the sheet immediately so the string is rarely shown).
    static func execute(
        description: String,
        using opener: ((String) -> Void)?
    ) -> String {
        guard let opener = opener, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Opening websites is not available right now."
        }
        opener(description)
        return "Opened the site for \"\(description)\" in a new tab (resolved privately)."
    }

    /// Details for the confirmation card (marker path or toolsEnabled==false).
    static func confirmationDetails(for payload: String) -> (icon: String, headline: String, body: String, payloadLine: String, approveLabel: String) {
        (
            "globe",
            "Open a website",
            "I'll use your private SearXNG instance to safely find the official or best matching site for the description and open it in a new browser tab. Everything stays local.",
            "Site / brand: “\(payload)”",
            "Find & open site"
        )
    }

    /// Strict, Apple-safeguard-aware detector for explicit navigation commands.
    /// Used by the chat sheet's early bypass (direct user intent → immediate open, no model).
    /// 
    /// Rules (per plan + user review on safeguards):
    /// - Must contain a clear imperative navigation verb/phrase.
    /// - MUST return false for any question-like or information-seeking phrasing, even if "open" appears
    ///   ("can you open elon musk's official chip facility website", "what is the tesla site?", "tell me about opening x").
    ///   These are knowledge requests → web_search + answer in chat (see AIRules.knowledgeFirst + navigationRule).
    /// - This is the primary defense against the exact reported bug (model or bypass treating descriptive
    ///   "can you open..." as a side-effecting navigation that then resolved to unrelated/sensitive content).
    static func isExplicitNavigationCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        // Apple-style safeguard: question / info-seeking framing always wins → never treat as raw nav bypass.
        if looksLikeQuestionOrInfoRequest(lower) {
            return false
        }

        return lower.hasPrefix("open ")
            || lower.contains("open the ")
            || lower.contains("go to ")
            || lower.contains("visit the ")
            || lower.contains("take me to ")
    }

    /// Conservative detector for polite questions, "tell me about", or other knowledge-seeking framing.
    /// If present, even a sentence containing "open ..." must go through the normal model/rules path
    /// (where the prompt explicitly says the exact bad example is a web_search case).
    private static func looksLikeQuestionOrInfoRequest(_ lower: String) -> Bool {
        lower.contains("can you")
            || lower.contains("could you")
            || lower.contains("would you")
            || lower.contains("what ")
            || lower.contains("who ")
            || lower.contains("how ")
            || lower.contains("why ")
            || lower.contains("tell me")
            || lower.contains("about the ")
            || lower.contains("is there")
            || lower.contains("?")
            || lower.contains("i want to know")
            || lower.contains("explain")
    }
}
