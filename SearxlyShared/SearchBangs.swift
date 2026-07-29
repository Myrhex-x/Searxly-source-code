//
//  SearchBangs.swift
//  SearxlyShared
//
//  DuckDuckGo-style search bangs (`!w tigers` → Wikipedia search), shared by the macOS and iOS
//  address bars so both resolve the same table.
//

import Foundation

enum SearchBangs {
    /// Maps bangs to their search URL templates. `%s` is replaced with the URL-encoded query.
    static let table: [String: String] = [
        "g":    "https://www.google.com/search?q=%s",
        "yt":   "https://www.youtube.com/results?search_query=%s",
        "gh":   "https://github.com/search?q=%s",
        "r":    "https://www.reddit.com/search/?q=%s",
        "so":   "https://stackoverflow.com/search?q=%s",
        "a":    "https://www.amazon.com/s?k=%s",
        "w":    "https://en.wikipedia.org/wiki/Special:Search?search=%s",
        "img":  "https://www.google.com/search?tbm=isch&q=%s",
        "maps": "https://www.google.com/maps/search/%s",
        "tw":   "https://twitter.com/search?q=%s",
        "npm":  "https://www.npmjs.com/search?q=%s",
        "pypi": "https://pypi.org/search/?q=%s",
        "wb":   "https://web.archive.org/web/*/%s",
        "ddg":  "https://duckduckgo.com/?q=%s",
        "b":    "https://www.bing.com/search?q=%s",
    ]

    /// If `query` starts with `!bang`, returns the resolved URL; otherwise nil.
    /// A bare bang with no query (`!gh`) goes to the site's search page with an empty term.
    static func resolve(_ query: String) -> URL? {
        guard query.hasPrefix("!") else { return nil }
        let parts = query.dropFirst().split(separator: " ", maxSplits: 1)
        guard parts.count >= 1 else { return nil }
        let bang = parts[0].lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard let template = table[bang] else { return nil }
        let encoded = rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rest
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
