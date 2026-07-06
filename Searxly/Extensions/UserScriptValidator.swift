//
//  UserScriptValidator.swift
//  Searxly
//
//  Static validation of a UserScript before it can be enabled. This is Layer 3 of the jailbreak /
//  abuse defense (see EXTENSION_IMPLEMENTATION_NOTES.md): it rejects the high-signal escape hatches that
//  the runtime sandbox wrapper cannot shadow (eval, the Function constructor, dynamic import, and the
//  `window.fetch` / `globalThis` / `.constructor` ways of reaching globals around the shadowed locals).
//
//  Honest scope: token scanning of JavaScript is inherently imperfect — a determined, hand-obfuscated
//  script could still evade it. That is why this is layered with (a) the prompt char cap, (b) structured
//  output, (c) the runtime shadowing wrapper, (d) the isolated content world with no native bridges, and
//  (e) mandatory human review before enable. No single layer is the whole story.
//

import Foundation

enum UserScriptValidation: Equatable {
    case valid
    case invalid([String])

    var isValid: Bool { if case .valid = self { return true } else { return false } }
    var reasons: [String] { if case .invalid(let r) = self { return r } else { return [] } }
}

enum UserScriptValidator {

    /// A forbidden construct: a regular-expression pattern and the human-readable reason shown to the user.
    private struct Rule {
        let pattern: String
        let reason: String
    }

    /// High-signal forbidden constructs. Kept deliberately specific so legitimate DOM tweaks
    /// (`window.addEventListener`, `window.location`, `document.querySelector`, …) are not rejected.
    private static let rules: [Rule] = [
        // Dynamic code execution.
        Rule(pattern: #"\beval\s*\("#, reason: "Uses eval() — dynamic code execution is not allowed."),
        Rule(pattern: #"\bnew\s+Function\b"#, reason: "Uses the Function constructor — dynamic code execution is not allowed."),
        Rule(pattern: #"\bFunction\s*\("#, reason: "Uses the Function constructor — dynamic code execution is not allowed."),
        Rule(pattern: #"\bimport\s*\("#, reason: "Uses dynamic import() — remote code loading is not allowed."),
        Rule(pattern: #"\.\s*constructor\b"#, reason: "Reaches .constructor — a known sandbox-escape vector."),
        Rule(pattern: #"\bglobalThis\b"#, reason: "References globalThis — escaping the script scope is not allowed."),

        // Network (the runtime wrapper shadows the bare globals; these catch the window/self/top escapes).
        Rule(pattern: #"\b(window|self|top|parent|globalThis)\s*\.\s*(fetch|XMLHttpRequest|WebSocket|EventSource)\b"#,
             reason: "Performs network requests — userscripts run offline."),
        Rule(pattern: #"\bnavigator\s*\.\s*sendBeacon\b"#, reason: "Uses sendBeacon — network exfiltration is not allowed."),
        Rule(pattern: #"\bimportScripts\s*\("#, reason: "Uses importScripts — remote code loading is not allowed."),

        // Native bridge / Searxly internals.
        Rule(pattern: #"\bwebkit\s*\.\s*messageHandlers\b"#, reason: "Reaches webkit.messageHandlers — Searxly's native bridge is off-limits."),
        Rule(pattern: #"\b(window|self)\s*\.\s*webkit\b"#, reason: "Reaches the webkit bridge — off-limits to userscripts."),

        // Extension APIs belong to Lane A (WKWebExtension), not userscripts.
        Rule(pattern: #"\bchrome\s*\.\s*(runtime|tabs|storage|extension|scripting|webRequest)\b"#,
             reason: "Uses chrome.* extension APIs — not available to userscripts."),
        Rule(pattern: #"\bbrowser\s*\.\s*(runtime|tabs|storage|extension|scripting|webRequest)\b"#,
             reason: "Uses browser.* extension APIs — not available to userscripts."),

        // Remote markup / popups.
        Rule(pattern: #"<\s*script"#, reason: "Injects a <script> tag — remote script injection is not allowed."),
        Rule(pattern: #"\bwindow\s*\.\s*open\s*\("#, reason: "Calls window.open — opening windows/popups is not allowed."),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap { rule in
        guard let re = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
        return (re, rule.reason)
    }

    /// Validates a script's structure (name, patterns, length caps) and scans its body for forbidden
    /// constructs. Returns `.valid` or `.invalid` with every reason found, so the UI can show them all.
    static func validate(_ script: UserScript) -> UserScriptValidation {
        var reasons: [String] = []

        // Name.
        let trimmedName = script.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            reasons.append("Name is empty.")
        } else if trimmedName.count > UserScriptLimits.maxNameChars {
            reasons.append("Name is too long (max \(UserScriptLimits.maxNameChars) characters).")
        }

        // Match patterns.
        if script.matchPatterns.isEmpty {
            reasons.append("No match patterns — a script must be scoped to at least one site.")
        }
        if script.matchPatterns.count > UserScriptLimits.maxPatterns {
            reasons.append("Too many match patterns (max \(UserScriptLimits.maxPatterns)).")
        }
        for pattern in script.matchPatterns where !UserScript.isValidMatchPattern(pattern) {
            reasons.append("Invalid match pattern: \(pattern)")
        }

        // Body length.
        let body = script.body
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("Script body is empty.")
        } else if body.count > UserScriptLimits.maxBodyChars {
            reasons.append("Script is too long (\(body.count) characters; max \(UserScriptLimits.maxBodyChars)).")
        }

        // Prompt length (AI-authored scripts).
        if let prompt = script.prompt, prompt.count > UserScriptLimits.promptCharLimit {
            reasons.append("Prompt is too long (max \(UserScriptLimits.promptCharLimit) characters).")
        }

        // Forbidden constructs.
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        for (re, reason) in compiled where re.firstMatch(in: body, range: fullRange) != nil {
            reasons.append(reason)
        }

        return reasons.isEmpty ? .valid : .invalid(reasons)
    }

    /// Convenience used by the AI authoring path (Phase 3) to reject an over-long prompt before it ever
    /// reaches the on-device model — Layer 1 of the defense.
    static func isPromptWithinLimit(_ prompt: String) -> Bool {
        prompt.count <= UserScriptLimits.promptCharLimit
    }
}
