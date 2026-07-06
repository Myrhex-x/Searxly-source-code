//
//  URL+Onion.swift
//  Searxly
//
//  Small shared helper for detecting Tor hidden-service URLs.
//

import Foundation

extension URL {
    /// True when the URL points at a Tor hidden service (host ends in `.onion`).
    var isOnionService: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "onion" || host.hasSuffix(".onion")
    }
}
