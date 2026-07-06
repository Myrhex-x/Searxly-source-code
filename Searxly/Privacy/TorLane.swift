//
//  TorLane.swift
//  Searxly
//
//  Shared network lane for native fetches that are SAFE TO ANONYMIZE: requests that carry no
//  user-identifying payload (public token/pool addresses, article slugs, search-result image URLs,
//  page URLs the AI was asked to read). Outside Maximum Privacy these ride the caller's normal
//  session. Inside Maximum Privacy the plain native lane is closed (PrivacyGate fails it closed so
//  nothing egresses from the real IP) — but these fetches don't need to die: routed through the
//  bundled Tor client they reveal only a Tor exit, which is exactly the promise of the mode. So the
//  lane substitutes a Tor-proxied session once Tor is verified up, and stays fail-closed otherwise
//  (Tor still bootstrapping, or VPN protection chosen but the tunnel down).
//
//  What must NEVER use this lane: address-keyed wallet traffic in the clear-lane sense is fine over
//  Tor in principle, but anything that would tie durable identity to a session (login flows, the
//  gateway's authenticated calls) keeps its own rules. See WalletNetwork.marketLane() for the
//  wallet's use and PrivacyGate for the enforcement map.
//

import Foundation
import Network

enum TorLane {

    /// The session (and how it egresses) for one anonymous native fetch.
    struct Lane: Sendable {
        let session: URLSession
        /// True when riding the bundled Tor client. Callers with a custom direct session (e.g. the
        /// thumbnail loader's disk-caching session) should use `lane.session` only when this is true;
        /// callers whose upstream blocks Tor exits (e.g. GeckoTerminal) pick a different source.
        let viaTor: Bool
    }

    /// Resolves the lane for one anonymous native fetch. `URLSession.shared` when native egress is
    /// open; the Tor-proxied session in Maximum Privacy + Tor once Tor is running; nil (fail closed)
    /// when neither lane is safe.
    static func current() async -> Lane? {
        if PrivacyGate.egressAllowedFast { return Lane(session: .shared, viaTor: false) }
        let torReady = await MainActor.run {
            PrivacyManager.shared.appPrivacyMode == .maximum
                && PrivacyManager.shared.maxProtection == .tor
                && TorManager.shared.isRunning
        }
        guard torReady else { return nil }
        return Lane(session: torSession, viaTor: true)
    }

    /// Cached Tor-proxied session (SOCKS5h — hostnames resolve at the proxy, no DNS leak). Ephemeral:
    /// nothing this lane fetches is ever cached to disk or carries cookies across launches, which is
    /// the right default for Maximum Privacy.
    private static let torSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: WebViewFactory.torSocksEndpoint())]
        config.timeoutIntervalForRequest = 25   // Tor circuits are slower than clearnet
        return URLSession(configuration: config)
    }()
}
