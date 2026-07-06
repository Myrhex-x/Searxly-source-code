//
//  AppLanguage.swift
//  Searxly
//
//  One language for all of Searxly. Default follows macOS Language & Region; the user can
//  override it in Settings → Search → Language, and that single choice drives BOTH the
//  interface (.lproj lookup + AppleLanguages on relaunch) and search results (SearXNG language=).
//

import Foundation

struct AppLanguage {
    /// ISO 639-1 language code (e.g. "en", "fr", "de").
    let code: String

    // MARK: - The one language override (set from Settings → Search → Language)

    /// UserDefaults key holding the user's explicit language choice — a full locale code
    /// ("fr-FR") or a bare language ("hi") where the local SearXNG only registers the base.
    /// Empty/absent = follow the system.
    static let overrideKey = "appLanguageOverride"

    /// The user's explicit in-app language choice. `nil` means "follow the system".
    /// Sanitized on read: this value crosses into search URLs and the Accept-Language header,
    /// so anything that isn't a plain locale code is treated as unset (defense-in-depth against
    /// a tampered UserDefaults value injecting query params or header lines).
    static var override: String? {
        let v = UserDefaults.standard.string(forKey: overrideKey) ?? ""
        return sanitizedLocaleCode(v)
    }

    /// Allowlist for locale codes: "en", "en-US" — letters, at most one hyphenated subtag.
    /// `nonisolated`: a pure string check with no main-actor state, so it can be passed as a plain
    /// function value (e.g. to `flatMap`) and called from any isolation.
    nonisolated static func sanitizedLocaleCode(_ raw: String) -> String? {
        guard !raw.isEmpty,
              raw.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{2,8})?$"#, options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    /// Applies a language choice everywhere: persists the override and mirrors it into
    /// AppleLanguages so a relaunch flips the ENTIRE app — Foundation formatters, system-provided
    /// strings, and WKWebView's Accept-Language — not just our own .lproj strings.
    /// Pass nil to go back to following the system.
    static func setOverride(_ code: String?) {
        let defaults = UserDefaults.standard
        if let code = code.flatMap(sanitizedLocaleCode) {
            defaults.set(code, forKey: overrideKey)
            defaults.set([code, "en"], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: overrideKey)
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    // MARK: - Resolution

    /// Active UI language: the explicit choice first (when we ship its .lproj), then the
    /// system preference list.
    static var current: AppLanguage {
        if let override {
            let base = baseCode(of: override)
            if Bundle.main.path(forResource: base, ofType: "lproj") != nil {
                return AppLanguage(code: base)
            }
        }
        return AppLanguage(code: resolvedSystemCode())
    }

    /// Walk preferred languages until we find a supported .lproj, otherwise English.
    private static func resolvedSystemCode() -> String {
        for localeID in Locale.preferredLanguages {
            let base = baseCode(of: localeID)
            if Bundle.main.path(forResource: base, ofType: "lproj") != nil {
                return base
            }
        }
        return "en"
    }

    /// Locale code sent to SearXNG (e.g. "en-US", "fr-FR", or a bare "hi").
    /// Priority: explicit in-app choice → macOS system language.
    /// Keeping the country suffix matters: search engines like Bing use it to pick
    /// a result region, which overrides IP-based geo-targeting. Returning just "en"
    /// leaves the country ambiguous and lets a French IP pull French content.
    static var systemSearchLanguageCode: String {
        if let override { return override }
        guard let preferred = Locale.preferredLanguages.first else { return "en-US" }
        // Normalize to the format SearXNG expects: lowercase-UPPERCASE (e.g. "en-US")
        let parts = preferred.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return "\(parts[0].lowercased())-\(parts[1].uppercased())"
        }
        return parts[0].lowercased()
    }

    static func baseCode(of localeID: String) -> String {
        localeID.split(separator: "-").first.map(String.init) ?? localeID
    }
}
