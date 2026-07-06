//  LocalSearxngManager.swift
//  Searxly
//
//  First-class in-app control for the user's private local SearXNG instance.
//  SearXNG runs as a bundled native Python process supervised by the
//  unsandboxed SearxlyHelper XPC service. UI surfaces in Onboarding +
//  Settings/InstancesSettingsView.
//

import Foundation
import SwiftUI
import Observation
import Security

enum SearxngStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)
}

/// Shared lean engine list for Searxly's local SearXNG (creation + optimization + migration).
enum LeanSearxngEngines {
    static let block = """
engines:
  # Lean SearXNG engines for Searxly private instance (button-driven auto setup).
  # Stable image-shipped engines only. Edit ~/searxng-local/searxng/settings.yml to expand.
  # Wikipedia engine removed: Searxly promotes Grokipedia client-side and suppresses Wikipedia
  # in the native SERP. Knowledge-panel enrichment still fetches wiki text via site: queries.

  # General-web engines. Multiple independent backends give the SERP both breadth (more results
  # per page) and depth (later pages keep yielding new results, so infinite scroll has somewhere to
  # go). From a typical residential IP the reliably-responding set is bing + duckduckgo + startpage
  # + brave + qwant; each (except duckduckgo) paginates, so scroll keeps finding new results.
  # Startpage is a Google proxy — it returns Google's own results without Google's bot-blocking, so
  # users still get Google-quality results even when the raw google engine is rate-limited.
  # google is kept because it's excellent when it does respond, but on many networks it returns
  # "too many requests" and is suspended gracefully (startpage covers it). mojeek/yahoo were dropped:
  # mojeek returns "access denied" and yahoo returns nothing from residential IPs, so they only
  # added latency without adding results.
  - name: google
    engine: google
    shortcut: go

  - name: bing
    engine: bing
    shortcut: bi

  - name: bing images
    engine: bing_images
    shortcut: bii
    categories: [images]

  - name: bing news
    engine: bing_news
    shortcut: bin
    categories: [news]

  # google_news is the freshest, broadest news source and works from residential IPs (RSS-based,
  # unlike the JS-walled `google` web engine). It ignores time_range/paging, so bing_news carries the
  # time-filter + infinite-scroll load; together they give the news tab real breadth and recency.
  - name: google news
    engine: google_news
    shortcut: gon
    categories: [news]

  # reuters: a wire service that returns REAL ISO publishedDate on every result (bing/google don't) —
  # so it drives accurate timestamps + LIVE badges + recency sort — and it stays up when google_news
  # gets rate-limited, so the tab never empties. sort_order=display_date:desc keeps it LIVE (the default
  # "relevance" surfaces years-old archive articles). yahoo_news was tested and dropped (dead from
  # residential IPs).
  - name: reuters
    engine: reuters
    shortcut: reut
    categories: [news]
    sort_order: "display_date:desc"

  - name: bing videos
    engine: bing_videos
    shortcut: biv
    categories: [videos]

  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg

  - name: startpage
    engine: startpage
    shortcut: sp

  - name: brave
    engine: brave
    shortcut: br

  - name: qwant
    engine: qwant
    shortcut: qw

  - name: openverse
    engine: openverse
    categories: [images]
    shortcut: opv

  - name: flickr
    engine: flickr_noapi
    shortcut: fl
    categories: [images]

  - name: deviantart
    engine: deviantart
    shortcut: da
    categories: [images]

  - name: dailymotion
    engine: dailymotion
    shortcut: dm
    categories: [videos]

  - name: vimeo
    engine: vimeo
    shortcut: vi
    categories: [videos]

  - name: github
    engine: github
    shortcut: gh
    categories: [it, repos]

  - name: currency
    engine: currency_convert
    shortcut: cc
"""

    /// Engines appended to existing lean installs that predate the 2026 media expansion.
    static let mediaMigrationEntries: [(marker: String, yaml: String)] = [
        ("  - name: flickr", """
  - name: flickr
    engine: flickr_noapi
    shortcut: fl
    categories: [images]
"""),
        ("  - name: deviantart", """
  - name: deviantart
    engine: deviantart
    shortcut: da
    categories: [images]
"""),
        ("  - name: dailymotion", """
  - name: dailymotion
    engine: dailymotion
    shortcut: dm
    categories: [videos]
"""),
        ("  - name: vimeo", """
  - name: vimeo
    engine: vimeo
    shortcut: vi
    categories: [videos]
""")
    ]
}

@Observable
@MainActor
final class LocalSearxngManager {
    static let shared = LocalSearxngManager()

    var status: SearxngStatus = .stopped
    var isBusy = false
    var lastError: String?
    var logs: [String] = []

    /// Whether the required ~/searxng-local project folder with searxng/settings.yml exists.
    var projectFolderExists = false

    /// When true, the local SearXNG publishes only on 127.0.0.1 (more secure).
    /// Normal users are always localhost-only. Developer Mode exposes an advanced LAN toggle.
    static let bindLocalhostOnlyKey = "SearXNG.BindLocalhostOnly"

    var bindToLocalhostOnly: Bool {
        get {
            migrateBindToLocalhostOnlyIfNeeded()
            if !DeveloperSettings.shared.isEnabled {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.bindLocalhostOnlyKey)
        }
        set {
            if !newValue && !DeveloperSettings.shared.isEnabled {
                return
            }
            UserDefaults.standard.set(newValue, forKey: Self.bindLocalhostOnlyKey)
        }
    }

    /// Whether Developer Mode allows changing the LAN exposure toggle.
    var canConfigureLANExposure: Bool {
        DeveloperSettings.shared.isEnabled
    }

    /// The bundled SearXNG version (for display in Settings).
    var bundledSearxngVersion: String { SearxngRuntimeConfig.bundledVersion }

    /// Absolute path to the bundled, signed Python interpreter that runs SearXNG.
    /// Shipped read-only at Searxly.app/Contents/Resources/searxng-runtime/python/bin/python3.12.
    var bundledRuntimePythonPath: String? {
        if let url = Bundle.main.url(
            forResource: "python3.12",
            withExtension: nil,
            subdirectory: "searxng-runtime/python/bin"
        ) {
            return url.path
        }
        // Fallback for flattened/alternate bundle layouts.
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("searxng-runtime/python/bin/python3.12").path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// UserDefaults key mirrored from ContentView's @AppStorage — gates background auto-start.
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    /// The user's REAL home directory (e.g. `/Users/alice`), resolved from the account record via
    /// `getpwuid(3)` rather than `FileManager.homeDirectoryForCurrentUser`.
    ///
    /// This app is sandboxed, so `homeDirectoryForCurrentUser` (and `NSHomeDirectory()`) is redirected
    /// to the container at `~/Library/Containers/<bundle-id>/Data`. But the bundled SearXNG runs under
    /// the UNSANDBOXED SearxlyHelper, whose file-operation allow-list is rooted at the *real*
    /// `~/searxng-local`. Both sides must name the exact same absolute path, so we resolve the true home
    /// here. `getpwuid` reads the account record and is not redirected by the sandbox; the app never
    /// touches this path directly (all I/O routes through the helper), so no file entitlement is needed.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Default location created by the onboarding "Create Local SearXNG Setup Folder" button.
    /// This is the canonical path Searxly uses for its private local instance. It must resolve to the
    /// real home (not the sandbox container) so it matches the unsandboxed helper's allow-list — see
    /// `realHomeDirectory`.
    let projectFolderURL: URL = LocalSearxngManager.realHomeDirectory
        .appendingPathComponent("searxng-local")

    /// Whether Searxly may start the local SearXNG instance without an explicit user action.
    /// Only true after onboarding is finished — never during the first-run flow.
    var mayAutoStartLocalContainer: Bool {
        UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey)
    }

    /// Default local instance URL respecting the localhost-only bind preference.
    var defaultLocalInstanceURL: String {
        bindToLocalhostOnly ? "http://127.0.0.1:8080" : "http://localhost:8080"
    }

    /// Probe order for local SearXNG health checks. IPv4 first — `localhost` often resolves to `::1`,
    /// which fails when SearXNG binds only on `127.0.0.1`.
    var localWebProbeURLs: [String] {
        if bindToLocalhostOnly {
            return ["http://127.0.0.1:8080"]
        }
        return ["http://127.0.0.1:8080", "http://localhost:8080"]
    }

    /// True only while the RUNNING local instance is verified to send its upstream engine traffic
    /// through Tor (outgoing.proxies patched + process restarted onto it). PrivacyGate's loopback
    /// search lane keys off this in Maximum Privacy + Tor — see LocalSearxngManager+TorRouting.
    var torSearchRouted = false

    /// Coalesces concurrent Tor-routing reconciles (mode flips while one is already in flight).
    var torRoutingReconcileTask: Task<Void, Never>?

    var currentTask: Task<Void, Never>?

    /// Coalesced launch warm-up (init + loadPersistedData must not each spawn readiness probes).
    var launchWarmUpTask: Task<Void, Never>?

    /// Coalesced user-initiated ensure path (search, Local AI, Settings).
    var ensureReadyTask: Task<Void, Never>?

    private init() {
        // projectFolderExists starts false; warm-up is scheduled only after loadPersistedData
        // confirms onboarding is complete (never from init — that races ahead of onboarding UI).
    }

}
