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
    var label: String {
        switch self {
        case .off: return "Off"
        case .moderate: return "Moderate"
        case .strict: return "Strict"
        }
    }
}

struct SearchLanguage: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all: [SearchLanguage] = [
        .init(code: "auto", label: "Automatic"),
        .init(code: "en", label: "English"),
        .init(code: "fr", label: "Français"),
        .init(code: "es", label: "Español"),
        .init(code: "de", label: "Deutsch"),
        .init(code: "it", label: "Italiano"),
        .init(code: "pt", label: "Português"),
        .init(code: "nl", label: "Nederlands"),
        .init(code: "ja", label: "日本語"),
        .init(code: "zh", label: "中文"),
        .init(code: "ru", label: "Русский"),
        .init(code: "ar", label: "العربية"),
    ]
}

@MainActor
@Observable
final class SearchSettings {
    static let shared = SearchSettings()

    private let key = "searxly.ios.instanceURL"

    /// Our hosted SearXNG instance — the shipped default.
    static let defaultInstance = "https://search.searxly.app"

    var instanceURL: String {
        didSet { UserDefaults.standard.set(instanceURL, forKey: key) }
    }

    /// Safe-search level passed to SearXNG (0 off / 1 moderate / 2 strict).
    var safeSearch: SafeSearch {
        didSet { UserDefaults.standard.set(safeSearch.rawValue, forKey: "searxly.ios.safeSearch") }
    }

    /// Preferred result language code ("auto" = let the instance decide).
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "searxly.ios.language") }
    }

    /// Save visited pages to local History.
    var saveHistory: Bool {
        didSet { UserDefaults.standard.set(saveHistory, forKey: "searxly.ios.saveHistory") }
    }

    /// Block JavaScript-initiated pop-up windows.
    var blockPopups: Bool {
        didSet { UserDefaults.standard.set(blockPopups, forKey: "searxly.ios.blockPopups") }
    }

    private init() {
        instanceURL = UserDefaults.standard.string(forKey: key) ?? Self.defaultInstance
        let defaults = UserDefaults.standard
        safeSearch = SafeSearch(rawValue: defaults.object(forKey: "searxly.ios.safeSearch") as? Int ?? 1) ?? .moderate
        language = defaults.string(forKey: "searxly.ios.language") ?? "auto"
        saveHistory = defaults.object(forKey: "searxly.ios.saveHistory") as? Bool ?? true
        blockPopups = defaults.object(forKey: "searxly.ios.blockPopups") as? Bool ?? true
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
