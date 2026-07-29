//
//  TorCircuitIsolation.swift
//  Searxly
//
//  First-party circuit keying for Searxly Maximum's Tor tabs (the Tor-Browser scheme, layered on
//  top of the torrc's destination isolation). What each layer covers:
//
//    • torrc `IsolateDestAddr IsolateDestPort` — streams to DIFFERENT destinations never share a
//      circuit, so navigating site A → site B already uses separate circuits.
//    • Per-tab SOCKS credentials (Tor's default `IsolateSOCKSAuth`) — two TABS never share a
//      circuit, even for the same destination.
//    • THIS layer — within one tab, streams to the SAME destination used to reuse one circuit
//      across first-party changes: browse site A then site B and a third party they both embed
//      (a shared CDN, an analytics host) kept riding the A-era circuit. Rotating the tab's SOCKS
//      credential whenever the main frame moves to a different first-party site forces fresh
//      circuits for everything, exactly like Tor Browser's URL-bar-domain keying. It also keeps
//      per-site isolation standing on its own if the torrc flags ever change.
//
//  The credential is a hash of (per-tab token, first-party site) — deterministic, so revisiting a
//  site in the same tab maps back to that site's circuits (stable exits for sessions), while the
//  random tab token keeps the same site unlinkable ACROSS tabs.
//
//  Honest limits:
//    • The first-party key is an approximated registrable domain (compact common-suffix list, not
//      the full Public Suffix List). A miss means a missed rotation — today's behaviour, never worse.
//    • The rotated credential applies to connections opened after the policy decision; a keep-alive
//      connection from the previous site can briefly outlive the rotation.
//

import CryptoKit
import Foundation
import Network
import WebKit

enum TorCircuitIsolation {

    /// Rotate the tab's SOCKS credential when the main frame moves to a different first-party site.
    /// Call from the navigation delegate BEFORE allowing a main-frame http(s) navigation, so the new
    /// credential is in place before the load opens its first connection. Searxly Maximum only; a
    /// no-op for non-Tor tabs (no proxy on the store) and for loopback / hostless URLs.
    @MainActor
    static func rotateIfNeeded(for webView: WKWebView, mainFrameURL url: URL) {
        guard Edition.isMaximum, let webView = webView as? SearxlyWebView else { return }
        let store = webView.configuration.websiteDataStore
        guard !store.proxyConfigurations.isEmpty else { return }   // not a Tor-routed tab
        guard let site = firstPartyKey(for: url) else { return }   // loopback / no host
        guard site != webView.torFirstPartySite else { return }    // same site — keep its circuits

        let token: String
        if let existing = webView.torCircuitTabToken {
            token = existing
        } else {
            token = UUID().uuidString
            webView.torCircuitTabToken = token
        }
        webView.torFirstPartySite = site
        let credential = credential(tabToken: token, site: site)
        store.proxyConfigurations = [WebViewFactory.makeTorProxyConfiguration(credential: credential)]
    }

    /// Deterministic per-(tab, site) SOCKS credential. Hashed so the site name never appears on the
    /// local SOCKS wire, and revisits map back to the same circuits.
    static func credential(tabToken: String, site: String) -> String {
        let digest = SHA256.hash(data: Data("\(tabToken)|\(site)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - First-party key (approximate registrable domain)

    /// Common multi-part public suffixes, so `shop.example.co.uk` keys as `example.co.uk` and two
    /// different `*.github.io` sites count as different parties. Deliberately compact: a suffix
    /// missing here only means a missed rotation (the destination isolation still applies).
    private static let twoPartSuffixes: Set<String> = [
        // ccTLD second levels
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "com.br", "net.br", "org.br", "gov.br",
        "com.mx", "com.ar", "com.tr", "com.co", "com.pe", "com.ve", "com.ec", "com.uy",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "com.hk", "com.sg", "com.my",
        "co.in", "net.in", "org.in", "gov.in", "ac.in", "firm.in",
        "co.kr", "or.kr", "go.kr", "ac.kr",
        "co.za", "org.za", "web.za", "gov.za",
        "com.ua", "in.ua", "org.ua",
        "com.pl", "net.pl", "org.pl",
        "co.il", "org.il", "ac.il",
        "com.eg", "com.sa", "com.vn", "com.ph", "com.pk", "com.bd", "com.ng",
        "co.ke", "co.id", "or.id", "co.th", "or.th", "ac.th", "in.th", "go.th",
        // Large multi-tenant hosting suffixes (PSL "private" section)
        "github.io", "gitlab.io", "netlify.app", "vercel.app", "pages.dev", "web.app",
        "firebaseapp.com", "herokuapp.com", "blogspot.com", "wordpress.com",
    ]

    /// The isolation key for a URL: its approximated registrable domain (lowercased), the raw host
    /// for IP literals and single-label hosts, or nil for loopback / hostless URLs (the local
    /// SearXNG UI must never count as a first party or claim a circuit).
    static func firstPartyKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return nil }
        if host.contains(":") { return host }                                     // IPv6 literal
        let labels = host.split(separator: ".").map(String.init)
        if labels.count <= 2 { return host }                                      // already eTLD+1 (or bare)
        if labels.allSatisfy({ label in label.allSatisfy(\.isNumber) }) { return host }   // IPv4 literal
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoPartSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }
}
