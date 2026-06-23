//
//  SearxngRuntimeConfig.swift
//  Searxly
//
//  The bundled native SearXNG runtime. SearXNG ships inside the app (no Docker) and is updated
//  via app releases. Keep `bundledVersion` in lockstep with scripts/build-searxng-runtime.sh
//  (SEARXNG_COMMIT) when bumping the bundled runtime.
//

import Foundation

enum SearxngRuntimeConfig {
    /// Bundled SearXNG version string (date-commit), for display in Settings.
    static let bundledVersion = "2025.2.12-d456f3dd9"
}
