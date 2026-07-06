//
//  SearchContentSafetyBlocklist.swift
//  Searxly
//
//  Open-source adult-domain blocklist loader (offline, bundled).
//  Source: HaGeZi's NSFW DNS Blocklist (nsfw-onlydomains.txt)
//  https://github.com/hagezi/dns-blocklists — see LICENSE in that repo.
//  Bundled snapshot: 2026-06-14 (~96k registrable domains).
//

import Foundation

/// Thread-safe loader for the bundled NSFW domain set.
/// `nonisolated` opts this type out of the module's default MainActor isolation (Swift 6).
/// Bundle URL must be installed from the main actor via `setCachedResourceURL(_:)`.
nonisolated enum SearchContentSafetyBlocklist: Sendable {
    static let resourceName = "hagezi-nsfw-onlydomains"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var domains: Set<String>?
    nonisolated(unsafe) private static var cachedResourceURL: URL?

    /// Installs the bundled list URL resolved on the main actor (`Bundle.main`).
    static func setCachedResourceURL(_ url: URL?) {
        cachedResourceURL = url
    }

    /// Returns true when `host` (or any parent domain) is in the bundled blocklist.
    static func isBlockedHost(_ host: String) -> Bool {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return false }

        let blocked = loadDomainsIfNeeded()
        var current = normalized
        while !current.isEmpty {
            if blocked.contains(current) { return true }
            guard let dot = current.firstIndex(of: ".") else { break }
            current = String(current[current.index(after: dot)...])
        }
        return false
    }

    /// For diagnostics / settings copy.
    static var loadedDomainCount: Int {
        loadDomainsIfNeeded().count
    }

    // MARK: - Loading

    private static func loadDomainsIfNeeded() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let domains { return domains }

        let parsed = parseBundledList()
        domains = parsed
        return parsed
    }

    private static func parseBundledList() -> Set<String> {
        guard let url = cachedResourceURL else {
            return fallbackDomains()
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackDomains()
        }

        var result = Set<String>()
        result.reserveCapacity(100_000)

        for line in text.split(whereSeparator: \.isNewline) {
            var entry = String(line).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if entry.isEmpty || entry.hasPrefix("#") { continue }
            if entry.hasPrefix("0.0.0.0 ") {
                entry = String(entry.dropFirst("0.0.0.0 ".count))
            }
            entry = normalizeHost(entry)
            if !entry.isEmpty, entry.contains(".") {
                result.insert(entry)
            }
        }

        if result.isEmpty {
            return fallbackDomains()
        }
        return result
    }

    private static func fallbackDomains() -> Set<String> {
        Set([
            "pornhub", "xvideos", "xhamster", "xnxx", "redtube", "youporn", "onlyfans",
            "chaturbate", "rule34", "imagefap", "redgifs", "literotica"
        ])
    }

    private static func normalizeHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("http://") || h.hasPrefix("https://") {
            h = URL(string: h)?.host?.lowercased() ?? h
        }
        if h.hasPrefix("www.") {
            h.removeFirst(4)
        }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}