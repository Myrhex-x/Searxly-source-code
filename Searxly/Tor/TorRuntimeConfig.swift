//
//  TorRuntimeConfig.swift
//  Searxly
//
//  Bundled Tor runtime config. Keep `bundledVersion` in lockstep with scripts/fetch-tor-runtime.sh.
//

import Foundation

enum TorRuntimeConfig {
    /// Bundled Tor (expert-bundle) version, shown in Settings. Match fetch-tor-runtime.sh TOR_VERSION.
    static let bundledVersion = "15.0.16"

    /// The local SOCKS5 endpoint Tor listens on. We deliberately do NOT use Tor's default 9050
    /// (system Tor) or 9150 (Tor Browser) so Searxly's private instance never collides with a
    /// Tor the user may already be running. Onion tabs route through this via a per-data-store
    /// ProxyConfiguration (SOCKS5h: hostnames — incl. .onion — resolve at the proxy, no DNS leak).
    static let socksHost = "127.0.0.1"
    static let socksPort: UInt16 = 19050
}
