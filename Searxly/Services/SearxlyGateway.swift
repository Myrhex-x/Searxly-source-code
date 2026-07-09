//
//  SearxlyGateway.swift
//  Searxly
//

import Foundation

// The app talks only to this gateway, which holds the real io.net / 0x keys server-side. The app
// token is a soft gate, not an upstream secret: supplied per-build via the SEARXLY_GATEWAY_APP_TOKEN
// env var or the SearxlyGatewayAppToken Info.plist key, with a blank fallback in the public source.
enum SearxlyGateway {
    nonisolated static let host = "https://gateway.searxly.app"

    nonisolated static let appToken: String = {
        if let env = ProcessInfo.processInfo.environment["SEARXLY_GATEWAY_APP_TOKEN"], !env.isEmpty {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "SearxlyGatewayAppToken") as? String,
           !plist.isEmpty {
            return plist
        }
        return fallbackAppToken
    }()

    private nonisolated static let fallbackAppToken = ""

    nonisolated static var isConfigured: Bool { !appToken.isEmpty }

    nonisolated static var aiBaseURL: URL { URL(string: "\(host)/v1")! }
    nonisolated static var zeroExBase: String { "\(host)/wallet/0x" }
    nonisolated static var etherscanBase: String { "\(host)/wallet/etherscan" }
    nonisolated static var bearer: String { "Bearer \(appToken)" }

    // Native local-pack (OpenStreetMap) place data. The gateway geocodes + runs Overpass, so OSM only ever
    // sees the gateway — never the user. The map picture is drawn natively (Apple MapKit). See gateway.mjs.
    nonisolated static var placesBase: String { "\(host)/places" }
}
