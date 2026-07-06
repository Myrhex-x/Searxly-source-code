//
//  SearxngRuntimeConfig.swift
//  Searxly
//
//  The bundled native SearXNG runtime. SearXNG ships inside the app and is updated
//  via app releases. Keep `bundledVersion` in lockstep with scripts/build-searxng-runtime.sh
//  (SEARXNG_COMMIT) when bumping the bundled runtime.
//

import Foundation

enum SearxngRuntimeConfig {
    /// Bundled SearXNG version string (date-commit), for display in Settings.
    /// `nonisolated`: a plain immutable constant, read from nonisolated contexts
    /// (SearchEngineHealthMonitor's staleness check).
    nonisolated static let bundledVersion = "2026.6.23-e371371"
}
