//
//  UserScript.swift
//  Searxly
//
//  Lane B — AI-authorable userscripts. The in-house, first-party extension format.
//
//  This is NOT a Chrome/Firefox WebExtension (that is Lane A — WKWebExtension, deferred). A UserScript
//  is a small, user-authored or AI-generated content script that runs in an ISOLATED content world on
//  the hosts the user explicitly scoped. Trust model: the user's own code, reviewed before it is
//  enabled — never a third-party signed binary. See EXTENSION_IMPLEMENTATION_NOTES.md.
//

import Foundation

/// A single user-authored or AI-generated content script.
///
/// Persisted in its own resilient file (`UserScripts.json`) — deliberately isolated from the encrypted
/// `AppData.json` schema, the same lesson learned for the password vault: feature data that can grow or
/// be edited frequently gets its own file so a parse failure can never take down core browser state.
struct UserScript: Identifiable, Codable, Equatable {

    /// Where the script came from. Surfaced in the UI as a trust badge and used for auditing.
    enum Author: String, Codable, Equatable {
        case manual   // typed or pasted by the user
        case ai       // generated on-device from a natural-language prompt (Phase 3)
    }

    /// When the body is injected relative to page parse.
    enum RunAt: String, Codable, Equatable {
        case documentStart
        case documentEnd
    }

    let id: UUID
    var name: String
    /// Chrome-style match patterns, e.g. `*://*.youtube.com/*` or `<all_urls>`.
    /// Matching is enforced at runtime by the injected prelude (see UserScriptManager).
    var matchPatterns: [String]
    /// The JavaScript body. Validated by `UserScriptValidator` before it can ever be enabled, and run
    /// inside a sandboxing wrapper that shadows network / native-bridge globals (UserScriptManager.wrap).
    var body: String
    var isEnabled: Bool
    var runAt: RunAt
    var author: Author
    var createdAt: Date
    /// For AI-authored scripts: the original natural-language prompt, retained for display + audit.
    /// Capped at `UserScriptLimits.promptCharLimit` at generation time.
    var prompt: String?

    init(
        id: UUID = UUID(),
        name: String,
        matchPatterns: [String],
        body: String,
        isEnabled: Bool = false,
        runAt: RunAt = .documentEnd,
        author: Author = .manual,
        createdAt: Date = Date(),
        prompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.matchPatterns = matchPatterns
        self.body = body
        self.isEnabled = isEnabled
        self.runAt = runAt
        self.author = author
        self.createdAt = createdAt
        self.prompt = prompt
    }
}

/// Hard limits shared by the validator, the (future) authoring UI, and the AI prompt path.
/// The character caps are one layer of the jailbreak/abuse defense — NOT the primary boundary.
/// The real containment is `UserScriptValidator` + the runtime sandbox wrapper + isolated content world.
enum UserScriptLimits {
    /// Max length of the user's natural-language prompt fed to the on-device model (Phase 3).
    /// A genuine request ("hide Shorts and comments on YouTube") is short; longer inputs are almost
    /// always roleplay/injection payloads, so we reject them before they ever reach the model.
    static let promptCharLimit = 280

    /// Max length of a generated/authored script body. Keeps every script human-reviewable and blocks
    /// giant obfuscated blobs.
    static let maxBodyChars = 4096

    /// Max number of match patterns per script.
    static let maxPatterns = 20

    /// Max length of a script's display name.
    static let maxNameChars = 80
}

// MARK: - Match pattern structural validity (Swift side)

extension UserScript {
    /// Lightweight structural check for a single Chrome-style match pattern. Runtime matching is done in
    /// JS by the prelude; this only rejects obviously malformed patterns at author/import time.
    /// Accepts `<all_urls>` and `<scheme>://<host><path>` where scheme is `*`, `http`, or `https`.
    static func isValidMatchPattern(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let schemeRange = pattern.range(of: "://") else { return false }
        let scheme = String(pattern[pattern.startIndex..<schemeRange.lowerBound])
        guard scheme == "*" || scheme == "http" || scheme == "https" else { return false }
        let rest = String(pattern[schemeRange.upperBound...])
        // Must have a host segment, then a path beginning with "/".
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let host = String(rest[rest.startIndex..<slash])
        guard !host.isEmpty else { return false }
        // Host may be "*", "*.domain", or a literal host. Reject stray spaces.
        if host.contains(" ") { return false }
        return true
    }
}
