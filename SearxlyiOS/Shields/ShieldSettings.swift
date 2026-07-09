//
//  ShieldSettings.swift
//  SearxlyiOS
//
//  All privacy-shield preferences in one observable place: content blocking, fingerprint
//  defense, GPC, HTTPS-Only, link cleaning, De-AMP, data hygiene, and the per-site shields
//  allow-list. Every write persists synchronously (project rule: durability is never deferred).
//

import Foundation
import Observation

@MainActor
@Observable
final class ShieldSettings {
    static let shared = ShieldSettings()

    private let defaults = UserDefaults.standard

    /// Master switch for the uBlock-based ad & tracker blocking (network rules + cosmetics).
    var blockAdsAndTrackers: Bool {
        didSet { defaults.set(blockAdsAndTrackers, forKey: "searxly.ios.shields.adblock") }
    }

    /// Dedicated YouTube ad blocking / skipping layer (rides on top of the master switch).
    var youtubeAdBlock: Bool {
        didSet { defaults.set(youtubeAdBlock, forKey: "searxly.ios.shields.youtube") }
    }

    /// Canvas / audio farbling + hardware clamps (per-session random seed, Brave-style).
    var fingerprintProtection: Bool {
        didSet { defaults.set(fingerprintProtection, forKey: "searxly.ios.shields.fingerprint") }
    }

    /// Global Privacy Control: Sec-GPC request header + navigator.globalPrivacyControl.
    var gpcSignal: Bool {
        didSet { defaults.set(gpcSignal, forKey: "searxly.ios.shields.gpc") }
    }

    /// Upgrade http:// navigations to https:// and ask before falling back.
    var httpsOnly: Bool {
        didSet { defaults.set(httpsOnly, forKey: "searxly.ios.shields.httpsOnly") }
    }

    /// Strip known tracking parameters (utm_*, fbclid, gclid, …) from navigations.
    var stripTrackingParams: Bool {
        didSet { defaults.set(stripTrackingParams, forKey: "searxly.ios.shields.stripParams") }
    }

    /// Rewrite Google/Bing AMP URLs to the canonical publisher page (De-AMP).
    var deAMP: Bool {
        didSet { defaults.set(deAMP, forKey: "searxly.ios.shields.deAMP") }
    }

    /// Wipe all website data left over from previous sessions at next launch.
    var clearDataOnExit: Bool {
        didSet { defaults.set(clearDataOnExit, forKey: "searxly.ios.shields.clearOnExit") }
    }

    /// Hide cookie-consent banners and their scroll locks (never auto-accepts — see CookieBannerShield).
    var blockCookieBanners: Bool {
        didSet { defaults.set(blockCookieBanners, forKey: "searxly.ios.shields.cookieBanners") }
    }

    /// Require Face ID / passcode to reveal private tabs after leaving the app (Safari/Chrome-style).
    var lockPrivateTabs: Bool {
        didSet { defaults.set(lockPrivateTabs, forKey: "searxly.ios.shields.lockPrivateTabs") }
    }

    /// Opt-in online search suggestions from the configured SearXNG instance while typing.
    /// Default OFF — keystrokes leave the device only if the user explicitly enables it.
    var onlineSuggestions: Bool {
        didSet { defaults.set(onlineSuggestions, forKey: "searxly.ios.shields.onlineSuggestions") }
    }

    /// Show real site icons on search results (anonymous well-known-path fetch from each result
    /// host — see FaviconStore). Turn off to guarantee zero pre-tap contact with result hosts.
    var resultSiteIcons: Bool {
        didSet { defaults.set(resultSiteIcons, forKey: "searxly.ios.shields.resultSiteIcons") }
    }

    /// Wikipedia knowledge cards on the SERP for entity queries (one anonymous summary fetch
    /// per matching search — never in private tabs).
    var knowledgeCards: Bool {
        didSet { defaults.set(knowledgeCards, forKey: "searxly.ios.shields.knowledgeCards") }
    }

    /// Grokipedia-first knowledge cards (macOS SERP source policy): when Grokipedia has the
    /// article, its opening paragraph is shown instead of Wikipedia's summary.
    var preferGrokipedia: Bool {
        didSet { defaults.set(preferGrokipedia, forKey: "searxly.ios.shields.preferGrokipedia") }
    }

    /// On-device AI Overview at the top of web results (auto for question-like queries,
    /// on-demand otherwise). Only surfaces when Apple Intelligence is available.
    var aiOverview: Bool {
        didSet { defaults.set(aiOverview, forKey: "searxly.ios.shields.aiOverview") }
    }

    /// Reopen last session's tabs at launch (never private ones; off when Clear on Exit is on).
    var restoreTabs: Bool {
        didSet { defaults.set(restoreTabs, forKey: "searxly.ios.shields.restoreTabs") }
    }

    /// Topic news feed on the start page — scroll down from the hero to browse headlines by topic.
    /// Fetched from the configured instance (categories=news), cached in memory only, never shown
    /// in private tabs. Default ON; turning it off keeps the start page a pure hero.
    var newsHomeFeed: Bool {
        didSet {
            defaults.set(newsHomeFeed, forKey: "searxly.ios.shields.newsHomeFeed")
            if !newsHomeFeed { HomeNewsFeed.shared.clear() }
        }
    }

    /// News topics the user hid from the start-page feed (by topic id). Everything is shown by default.
    private(set) var hiddenNewsTopics: Set<String> {
        didSet { defaults.set(Array(hiddenNewsTopics), forKey: "searxly.ios.shields.hiddenNewsTopics") }
    }

    func isNewsTopicVisible(_ id: String) -> Bool { !hiddenNewsTopics.contains(id) }

    func setNewsTopic(_ id: String, visible: Bool) {
        if visible { hiddenNewsTopics.remove(id) } else { hiddenNewsTopics.insert(id) }
    }

    // MARK: - Per-site shields

    /// Hosts where the user turned shields down (network rule lists disabled after reload).
    private(set) var shieldsOffHosts: Set<String> {
        didSet { defaults.set(Array(shieldsOffHosts), forKey: "searxly.ios.shields.offHosts") }
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func shieldsEnabled(forHost host: String?) -> Bool {
        guard blockAdsAndTrackers else { return false }
        guard let h = Self.normalizedHost(host) else { return true }
        return !shieldsOffHosts.contains(h)
    }

    func setShields(_ on: Bool, forHost host: String?) {
        guard let h = Self.normalizedHost(host) else { return }
        if on { shieldsOffHosts.remove(h) } else { shieldsOffHosts.insert(h) }
    }

    func clearShieldsExceptions() { shieldsOffHosts = [] }

    // MARK: - Tracker tally (lifetime)

    /// Lifetime count of tracker/ad requests attempted against pages the user visited while
    /// shields were up. Approximate by design (see TrackerTally) — a floor, not an exact audit.
    private(set) var lifetimeTrackersBlocked: Int {
        didSet {
            defaults.set(lifetimeTrackersBlocked, forKey: "searxly.ios.shields.lifetimeBlocked")
            SharedPrivacyStats.setLifetimeBlocked(lifetimeTrackersBlocked)  // feed the Home Screen widget
        }
    }

    /// Per-tracker-domain hit counts (top offenders for the Privacy Report). Tracker company
    /// domains only — never the sites the user visited.
    private(set) var trackerDomainCounts: [String: Int] {
        didSet { defaults.set(trackerDomainCounts, forKey: "searxly.ios.shields.trackerDomains") }
    }

    func addBlockedTrackers(_ n: Int, domains: [String] = []) {
        guard n > 0 else { return }
        lifetimeTrackersBlocked += n
        guard !domains.isEmpty else { return }
        var counts = trackerDomainCounts
        for d in domains { counts[d, default: 0] += 1 }
        // Keep the table bounded: prune to the 100 biggest offenders.
        if counts.count > 100 {
            counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
        trackerDomainCounts = counts
    }

    var topTrackers: [(domain: String, count: Int)] {
        trackerDomainCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (domain: $0.key, count: $0.value) }
    }

    func resetStats() {
        lifetimeTrackersBlocked = 0
        trackerDomainCounts = [:]
    }

    // MARK: - Init

    private init() {
        func bool(_ key: String, default def: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) as? Bool ?? def
        }
        blockAdsAndTrackers = bool("searxly.ios.shields.adblock", default: true)
        youtubeAdBlock = bool("searxly.ios.shields.youtube", default: true)
        fingerprintProtection = bool("searxly.ios.shields.fingerprint", default: true)
        gpcSignal = bool("searxly.ios.shields.gpc", default: true)
        httpsOnly = bool("searxly.ios.shields.httpsOnly", default: true)
        stripTrackingParams = bool("searxly.ios.shields.stripParams", default: true)
        deAMP = bool("searxly.ios.shields.deAMP", default: true)
        clearDataOnExit = bool("searxly.ios.shields.clearOnExit", default: false)
        blockCookieBanners = bool("searxly.ios.shields.cookieBanners", default: true)
        lockPrivateTabs = bool("searxly.ios.shields.lockPrivateTabs", default: false)
        onlineSuggestions = bool("searxly.ios.shields.onlineSuggestions", default: false)
        resultSiteIcons = bool("searxly.ios.shields.resultSiteIcons", default: true)
        knowledgeCards = bool("searxly.ios.shields.knowledgeCards", default: true)
        preferGrokipedia = bool("searxly.ios.shields.preferGrokipedia", default: true)
        aiOverview = bool("searxly.ios.shields.aiOverview", default: true)
        restoreTabs = bool("searxly.ios.shields.restoreTabs", default: true)
        newsHomeFeed = bool("searxly.ios.shields.newsHomeFeed", default: true)
        hiddenNewsTopics = Set(UserDefaults.standard.stringArray(forKey: "searxly.ios.shields.hiddenNewsTopics") ?? [])
        shieldsOffHosts = Set(UserDefaults.standard.stringArray(forKey: "searxly.ios.shields.offHosts") ?? [])
        lifetimeTrackersBlocked = UserDefaults.standard.integer(forKey: "searxly.ios.shields.lifetimeBlocked")
        trackerDomainCounts = (UserDefaults.standard.dictionary(forKey: "searxly.ios.shields.trackerDomains") as? [String: Int]) ?? [:]
    }
}
