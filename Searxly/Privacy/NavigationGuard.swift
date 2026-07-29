//
//  NavigationGuard.swift
//  Searxly
//
//  Request-level privacy hardening, applied from the web view's navigation delegate. These close
//  leaks that live in the REQUEST itself — the URL and its headers — which no transport (Tor/VPN) or
//  fingerprint defense touches, because they travel inside the request:
//
//    · Link cleaning — strips known tracking parameters (utm_*, fbclid, gclid, …). A `?fbclid=…` is a
//      plaintext cross-site identity tag that survives Tor and farbling.
//    · GPC — the legally-binding Global Privacy Control opt-out (Sec-GPC: 1 header + a JS property).
//    · HTTPS-Only — upgrades http:// to https:// so a page can't load in the clear.
//
//  Ported from the SearxlyiOS shields (the desktop app was missing all three). Pure URL logic lives
//  here as static functions so it is unit-testable; the delegate wiring calls into it. The user-facing
//  toggles live in `PrivacyShieldSettings`; the richer defaults are Searxly Maximum's.
//

import Foundation
import WebKit

enum NavigationGuard {

    // MARK: - Tracking-parameter stripping

    /// Exact parameter names that exist only for cross-site tracking / click attribution.
    static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid",
        "igshid", "igsh", "yclid", "srsltid", "s_cid", "scid", "mc_cid", "mc_eid", "mkt_tok",
        "_hsenc", "_hsmi", "hsa_acc", "hsa_cam", "hsa_grp", "hsa_ad", "hsa_src", "hsa_tgt",
        "hsa_kw", "hsa_mt", "hsa_net", "hsa_ver", "oly_anon_id", "oly_enc_id", "vero_conv",
        "vero_id", "wickedid", "rb_clickid", "irclickid", "sc_cid", "ml_subscriber",
        "ml_subscriber_hash", "_openstat", "ss_email_id", "bsft_clkid", "bsft_uid", "et_rid",
        "cmpid", "guccounter", "guce_referrer", "guce_referrer_sig", "spm", "ncid",
    ]

    /// Prefixes: any parameter starting with these is tracking (utm_source, pk_campaign, …).
    static let trackingPrefixes = ["utm_", "pk_", "piwik_", "matomo_", "itm_", "elqTrack"]

    /// Returns a cleaned URL if tracking parameters were removed, nil when nothing to strip.
    static func strippingTrackingParams(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return nil }

        let kept = items.filter { item in
            let name = item.name.lowercased()
            if trackingParams.contains(name) { return false }
            if trackingPrefixes.contains(where: { name.hasPrefix($0.lowercased()) }) { return false }
            return true
        }
        guard kept.count != items.count else { return nil }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    // MARK: - HTTPS-Only

    /// Whether `url` should be upgraded to https — a plain-http web URL to a real host (never
    /// localhost, .local, or a raw IPv4, where https typically has no valid cert).
    static func shouldUpgradeToHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host != "localhost" && !host.hasSuffix(".local") && !isIPv4(host)
    }

    /// Returns the https:// form of an http:// URL.
    static func upgradedToHTTPS(_ url: URL) -> URL? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "https"
        return comps?.url
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - Scheme classification

    /// Schemes the web view handles itself (everything else is an external-app handoff).
    static func isWebScheme(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return s == "http" || s == "https" || s == "about" || s == "blob" || s == "data" || s == "javascript"
    }

    // MARK: - GPC user script

    /// The JS half of Global Privacy Control: `navigator.globalPrivacyControl === true`. The Sec-GPC
    /// header half is added on main-frame GET requests in the navigation delegate.
    static let gpcUserScriptSource = """
    (function() {
        'use strict';
        try {
            Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {
                get: function () { return true; }, enumerable: true, configurable: true
            });
        } catch (e) {}
    })();
    """
}
