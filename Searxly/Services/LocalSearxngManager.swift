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
  # go). google is the strongest single source (~20/page + reliable deep pagination); bing/mojeek/
  # yahoo add diversity and paginate well. brave & startpage were removed — from a residential IP
  # they consistently return zero (blocked), so they only diluted the set without adding results.
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

  - name: bing videos
    engine: bing_videos
    shortcut: biv
    categories: [videos]

  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg

  - name: mojeek
    engine: mojeek
    shortcut: mjk

  - name: yahoo
    engine: yahoo
    shortcut: yh

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

    /// Default location created by the onboarding "Create Local SearXNG Setup Folder" button.
    /// This is the canonical path Searxly uses for its private local instance.
    let projectFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
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
