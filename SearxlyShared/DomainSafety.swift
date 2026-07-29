//
//  DomainSafety.swift
//  Searxly
//
//  Anti-spoofing helpers for how a host is shown to the user — the address bar and the site-privacy
//  popover are where someone decides "is this the real site?", so a spoofed host there is a direct
//  phishing risk.
//
//  Two defenses:
//    1. Homograph policy (`displayHost`) — a URL like `аpple.com` (Cyrillic а) is a different site
//       that reads as "apple.com". Foundation's `URL.host` already returns the punycode (`xn--…`)
//       form, so we're not silently spoofed — but that means EVERY internationalized domain shows as
//       ugly `xn--…`, even legitimate ones (münchen.de, 日本.jp). This restores friendly Unicode for
//       hosts that are unambiguous (single, non-Latin-lookalike script) while KEEPING punycode for
//       the ones that could be a spoof (mixed scripts, or the Latin-lookalike Cyrillic/Greek).
//    2. Registrable-domain emphasis (`registrableDomain`) — `apple.com.evil.ru/login` reads as
//       "apple.com…" at a glance; emphasizing the true registrable domain (evil.ru) in the address
//       bar is the standard defense. Foundation does nothing here.
//

import Foundation

enum DomainSafety {

    // MARK: - Homograph-safe display host

    /// The host to SHOW for a URL: friendly Unicode when the internationalized host is unambiguous,
    /// the punycode `xn--` form when it could be a homograph spoof. Pure ASCII hosts pass through.
    static func displayHost(for url: URL) -> String {
        let punycode = (url.host ?? "").lowercased()   // Foundation returns ASCII/punycode here
        guard let unicode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
              unicode != punycode else {
            return punycode   // pure ASCII (or an xn-- that doesn't decode) — nothing to decide
        }
        return isUnambiguousUnicodeHost(unicode) ? unicode : punycode
    }

    /// Same policy for a bare host string (used where only the host is available). If the host is
    /// already ASCII/punycode it's returned unchanged.
    static func displayHost(forHost host: String) -> String {
        let lower = host.lowercased()
        // Reconstruct enough of a URL to reuse the URL path; if it doesn't parse, treat as ASCII.
        guard let url = URL(string: "http://\(lower)") else { return lower }
        return displayHost(for: url)
    }

    /// A Unicode host is safe to show as Unicode only if EVERY label is unambiguous.
    static func isUnambiguousUnicodeHost(_ host: String) -> Bool {
        host.split(separator: ".").allSatisfy { isUnambiguousLabel(String($0)) }
    }

    /// A label is unambiguous when it is a single non-confusable script. Conservative on purpose:
    ///   · any Cyrillic or Greek (the scripts full of Latin lookalikes) → NOT safe, show punycode
    ///   · a mix of script families within one label → NOT safe (classic homograph)
    ///   · all-Latin (incl. accented: café, münchen) → safe
    ///   · a single non-Latin script (CJK, Arabic, Thai, Hebrew, …) → safe (doesn't resemble Latin)
    static func isUnambiguousLabel(_ label: String) -> Bool {
        var families = Set<ScriptFamily>()
        for scalar in label.unicodeScalars {
            let family = scriptFamily(scalar)
            if family == .neutral { continue }
            // Cyrillic / Greek carry the highest homograph risk against Latin — never auto-Unicode.
            if family == .cyrillic || family == .greek { return false }
            families.insert(family)
        }
        return families.count <= 1
    }

    enum ScriptFamily: Hashable { case latin, cyrillic, greek, cjk, otherScript, neutral }

    /// Coarse script classification by scalar range — enough to separate Latin, the two
    /// Latin-lookalike scripts (Cyrillic/Greek), CJK, and "other non-Latin".
    static func scriptFamily(_ s: Unicode.Scalar) -> ScriptFamily {
        let v = s.value
        // Digits, hyphen, and other host-legal punctuation are script-neutral.
        if s == "-" || (v >= 0x30 && v <= 0x39) { return .neutral }
        // ASCII + Latin-1/extended letters (accented Latin: à á â ä … ü, Ā-ſ, Latin Extended).
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            || (v >= 0x00C0 && v <= 0x024F) { return .latin }
        if v >= 0x0370 && v <= 0x03FF { return .greek }
        if v >= 0x0400 && v <= 0x04FF { return .cyrillic }
        // CJK ideographs + Hiragana/Katakana + Hangul.
        if (v >= 0x3040 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x9FFF)
            || (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0xF900 && v <= 0xFAFF) { return .cjk }
        return .otherScript
    }

    // MARK: - Registrable domain (for address-bar emphasis)

    /// The registrable domain ("eTLD+1") of a host — what a person should read as the site identity
    /// (e.g. `evil.ru` for `apple.com.evil.ru`). Approximate: a compact multi-part-suffix list, not
    /// the full Public Suffix List. Returns nil for IPs / single-label / empty hosts (nothing to
    /// emphasize). This is display-only; a miss just means no emphasis, never a wrong security call.
    static func registrableDomain(_ host: String) -> String? {
        let h = host.lowercased()
        guard !h.isEmpty, !h.contains(":") else { return nil }          // no IPv6
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }                     // single label / bare host
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }  // IPv4
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Splits a host for address-bar / popover emphasis: the dimmed subdomain `prefix` (with its
    /// trailing dot) and the bold `registrable` site identity. `apple.com.evil.ru` → ("apple.com.",
    /// "evil.ru"). Applies homograph-safe display first, so the emphasized text is never a spoof.
    static func emphasisSplit(forHost host: String) -> (prefix: String, registrable: String) {
        let display = displayHost(forHost: host)
        guard let registrable = registrableDomain(display),
              let range = display.range(of: registrable, options: .backwards) else {
            return ("", display)
        }
        return (String(display[display.startIndex..<range.lowerBound]), registrable)
    }

    /// Common multi-part public suffixes, so `bbc.co.uk` emphasizes `bbc.co.uk`, not `co.uk`.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "com.hk", "com.sg", "com.my", "com.mx", "com.ar", "com.tr", "com.co",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.kr", "or.kr", "go.kr",
        "co.za", "org.za", "gov.za",
        "com.ua", "com.pl", "co.il", "com.sa", "com.ng", "co.ke", "co.id", "co.th",
        "github.io", "gitlab.io", "netlify.app", "vercel.app", "pages.dev", "web.app",
    ]
}
