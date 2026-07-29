//
//  SearchSettings.swift
//  SearxlyiOS
//
//  The SearXNG instance the app searches against. Defaults to our own hosted instance
//  (search.searxly.app), and is user-overridable + persisted (Settings ▸ Search instance).
//

import Foundation
import Observation

enum SafeSearch: Int, CaseIterable, Identifiable {
    case off = 0, moderate = 1, strict = 2
    var id: Int { rawValue }
    @MainActor var label: String {
        switch self {
        case .off: return L("Off")
        case .moderate: return L("Moderate")
        case .strict: return L("Strict")
        }
    }
}

struct SearchLanguage: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    /// Prefer `AppLocale.supported` in Settings (full list). This is a small static fallback.
    static let all: [SearchLanguage] = [
        .init(code: "auto", label: "Automatic"),
        .init(code: "en", label: "English"),
        .init(code: "fr", label: "Français"),
        .init(code: "es", label: "Español"),
        .init(code: "de", label: "Deutsch"),
    ]
}

@MainActor
@Observable
final class SearchSettings {
    static let shared = SearchSettings()

    private let key = "searxly.ios.instanceURL"

    /// Our hosted SearXNG instance — the shipped default.
    static let defaultInstance = "https://search.searxly.app"

    /// Whether users may point the app at a custom SearXNG instance (Settings ▸ Search ▸ Advanced).
    /// The default stays the hosted instance; self-hosters and the SearXNG community get the editor.
    static let allowsCustomInstance = true

    var instanceURL: String {
        didSet { UserDefaults.standard.set(instanceURL, forKey: key) }
    }

    /// Safe-search level passed to SearXNG (0 off / 1 moderate / 2 strict).
    var safeSearch: SafeSearch {
        didSet { UserDefaults.standard.set(safeSearch.rawValue, forKey: "searxly.ios.safeSearch") }
    }

    /// Preferred result language code. Default `"auto"` = device system language (or App Language
    /// override when set). Any explicit ISO code forces that language for search/wiki/AI content.
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "searxly.ios.language") }
    }

    /// Concrete language code for SearXNG / Wikipedia / AI grounding.
    /// - explicit pick → that code (any language)
    /// - `"auto"` → active app language (System device language, unless App Language is overridden)
    @MainActor
    var resolvedContentLanguage: String {
        if language != "auto", !language.isEmpty {
            return AppLocale.normalizeLanguageCode(language)
        }
        return AppLocale.shared.languageCode
    }

    /// Wikipedia subdomain for knowledge cards (aliases like nb→no applied).
    @MainActor
    var resolvedWikipediaLanguage: String {
        AppLocale.wikipediaCode(for: resolvedContentLanguage)
    }

    /// Accept-Language value for search requests (keeps system region when on Automatic).
    @MainActor
    var resolvedAcceptLanguage: String {
        if language != "auto", !language.isEmpty {
            return "\(AppLocale.normalizeLanguageCode(language)),en;q=0.5"
        }
        return AppLocale.shared.acceptLanguageHeader
    }

    /// Save visited pages to local History.
    var saveHistory: Bool {
        didSet { UserDefaults.standard.set(saveHistory, forKey: "searxly.ios.saveHistory") }
    }

    /// Block JavaScript-initiated pop-up windows.
    var blockPopups: Bool {
        didSet { UserDefaults.standard.set(blockPopups, forKey: "searxly.ios.blockPopups") }
    }

    /// Let audio and video keep playing after you leave the app or lock the screen.
    ///
    /// Default OFF, deliberately: pausing everything on background is what fixed the "Searxly
    /// drains the battery all day" bug, because a page autoplaying media keeps WebKit's media
    /// session — and the whole app — awake. Turning this on narrows that rule rather than removing
    /// it; only the tab you are actually watching is exempt. See MediaPlayback.
    var backgroundMedia: Bool {
        didSet {
            UserDefaults.standard.set(backgroundMedia, forKey: "searxly.ios.backgroundMedia")
            MainActor.assumeIsolated { MediaPlayback.configureAudioSession() }
        }
    }

    private init() {
        instanceURL = UserDefaults.standard.string(forKey: key) ?? Self.defaultInstance
        let defaults = UserDefaults.standard
        safeSearch = SafeSearch(rawValue: defaults.object(forKey: "searxly.ios.safeSearch") as? Int ?? 1) ?? .moderate
        language = defaults.string(forKey: "searxly.ios.language") ?? "auto"
        saveHistory = defaults.object(forKey: "searxly.ios.saveHistory") as? Bool ?? true
        blockPopups = defaults.object(forKey: "searxly.ios.blockPopups") as? Bool ?? true
        backgroundMedia = defaults.object(forKey: "searxly.ios.backgroundMedia") as? Bool ?? false
    }

    /// Trimmed, trailing-slash-free base URL, falling back to the default when blank/invalid.
    var base: String {
        var s = instanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty || URL(string: s) == nil { return Self.defaultInstance }
        return s
    }

    var homeURL: URL { URL(string: base) ?? URL(string: Self.defaultInstance)! }

    /// Builds the SearXNG search URL for a query against the configured instance.
    func searchURL(for query: String) -> URL? {
        var comps = URLComponents(string: "\(base)/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps?.url
    }

    /// Whether the app is pointed at our default instance (vs a user-supplied one).
    var isUsingDefault: Bool { base == Self.defaultInstance }

    /// Ordered instances to try for a search: the configured one first, then JSON-API-enabled
    /// public backups. Search is the app's core function and a single instance is a single point
    /// of failure — if the primary is down or rate-limited, the client rotates to the next.
    /// (Only used when the user is on our default; a user-supplied custom instance is respected
    /// as-is, since they chose it deliberately.)
    static let fallbackInstances = [
        "https://searx.be",
        "https://search.inetol.net",
        "https://priv.au",
    ]

    var searchInstances: [String] {
        guard isUsingDefault else { return [base] }
        var list = [base]
        for f in Self.fallbackInstances where !list.contains(f) { list.append(f) }
        return list
    }
}
