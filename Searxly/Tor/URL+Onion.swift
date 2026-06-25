//
//  URL+Onion.swift
//  Searxly
//
//  Small shared helper for detecting Tor hidden-service URLs.
//

import Foundation

extension URL {
    /// True when this URL points at a Tor hidden service (host ends in `.onion`).
    /// Such URLs are only reachable through Tor, so they are routed into a dedicated onion tab.
    var isOnionService: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "onion" || host.hasSuffix(".onion")
    }
}
