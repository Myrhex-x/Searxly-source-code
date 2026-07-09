//
//  NavigationGuard.swift
//  SearxlyiOS
//
//  Per-navigation privacy policy, applied from the web view's navigation delegate:
//    · Link cleaning — strips known tracking parameters (utm_*, fbclid, gclid, …)
//    · De-AMP — rewrites Google/Bing AMP URLs to the canonical publisher page
//    · HTTPS-Only — upgrades http:// and asks before ever falling back
//    · GPC — adds the Sec-GPC: 1 header to main-frame GET requests
//    · External schemes (tel/mailto/sms/app links) — confirmed with the user, never silent
//
//  Pure URL logic lives here as static functions (testable); the delegate object at the bottom
//  is owned by BrowserModel.
//

import Foundation
import WebKit

enum NavigationGuard {

    // MARK: - Tracking-parameter stripping

    /// Exact parameter names known to exist only for cross-site tracking / click attribution.
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid",
        "igshid", "igsh", "yclid", "srsltid", "s_cid", "scid", "mc_cid", "mc_eid", "mkt_tok",
        "_hsenc", "_hsmi", "hsa_acc", "hsa_cam", "hsa_grp", "hsa_ad", "hsa_src", "hsa_tgt",
        "hsa_kw", "hsa_mt", "hsa_net", "hsa_ver", "oly_anon_id", "oly_enc_id", "vero_conv",
        "vero_id", "wickedid", "rb_clickid", "irclickid", "sc_cid", "ml_subscriber",
        "ml_subscriber_hash", "_openstat", "ss_email_id", "bsft_clkid", "bsft_uid", "et_rid",
        "cmpid", "guccounter", "guce_referrer", "guce_referrer_sig", "spm", "ncid",
    ]

    /// Prefixes: any parameter starting with these is tracking (utm_source, pk_campaign, …).
    private static let trackingPrefixes = ["utm_", "pk_", "piwik_", "matomo_", "itm_", "elqTrack"]

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

    // MARK: - De-AMP

    /// Rewrites AMP-cache URLs (google.com/amp/…, *.cdn.ampproject.org, bing.com/amp/…) to the
    /// canonical publisher URL. Returns nil when the URL isn't an AMP-cache page.
    static func deAMP(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }

        // https://www.google.com/amp/s/example.com/path → https://example.com/path
        if (host == "www.google.com" || host == "google.com" || host.hasSuffix(".google.com")
            || host == "www.bing.com" || host == "bing.com"),
           url.path.hasPrefix("/amp/") {
            var rest = String(url.path.dropFirst("/amp/".count))
            var scheme = "http"
            if rest.hasPrefix("s/") { scheme = "https"; rest = String(rest.dropFirst(2)) }
            var restored = "\(scheme)://\(rest)"
            if let q = url.query, !q.isEmpty { restored += "?\(q)" }
            return URL(string: restored)
        }

        // https://example-com.cdn.ampproject.org/c/s/example.com/path → https://example.com/path
        if host.hasSuffix(".cdn.ampproject.org") || host.hasSuffix(".ampproject.net") {
            let path = url.path
            for marker in ["/c/s/", "/v/s/"] where path.hasPrefix(marker) {
                var restored = "https://" + path.dropFirst(marker.count)
                if let q = url.query, !q.isEmpty { restored += "?\(q)" }
                return URL(string: restored)
            }
            for marker in ["/c/", "/v/"] where path.hasPrefix(marker) {
                var restored = "http://" + path.dropFirst(marker.count)
                if let q = url.query, !q.isEmpty { restored += "?\(q)" }
                return URL(string: restored)
            }
        }
        return nil
    }

    // MARK: - Scheme classification

    /// Schemes the web view handles itself.
    static func isWebScheme(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return s == "http" || s == "https" || s == "about" || s == "blob" || s == "data" || s == "javascript"
    }
}

// MARK: - Navigation delegate

/// Owned by BrowserModel. Applies the guard policies, drives the HTTPS-Only fallback and
/// external-app confirmations through observable state on the model.
@MainActor
final class WebNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var model: BrowserModel?

    /// Hosts the user explicitly allowed over plain HTTP (session-only, never persisted).
    private var httpAllowedHosts: Set<String> = []

    /// Main-frame URLs we already upgraded http→https, so a load failure can offer HTTP fallback.
    private var upgradedURLs: [String: URL] = [:]  // https URL string → original http URL

    /// URLs we already re-issued with the Sec-GPC header (loop guard).
    private var gpcHandled: Set<String> = []

    func allowHTTP(forHost host: String) {
        httpAllowedHosts.insert(host.lowercased())
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             preferences: WKWebpagePreferences,
                             decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        MainActor.assumeIsolated {
            // Per-site "Request Desktop Website" — applied to the navigation's own preferences,
            // so remembered hosts load their preferred mode without a second reload.
            if navigationAction.targetFrame?.isMainFrame ?? true {
                let site = PerSiteSettings.shared.settings(forHost: navigationAction.request.url?.host)
                preferences.preferredContentMode = (site.desktopMode ?? false) ? .desktop : .mobile
            }
            decisionHandler(decide(webView, navigationAction), preferences)
        }
    }

    private func decide(_ webView: WKWebView, _ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        let settings = ShieldSettings.shared

        // 1. Non-web schemes → confirm before leaving the app. javascript:/about:/data: pass through.
        if !NavigationGuard.isWebScheme(url) {
            model?.requestExternalOpen(url)
            return .cancel
        }

        // Subframes: allow (rule lists police their resources; rewriting subframe URLs breaks embeds).
        guard action.targetFrame?.isMainFrame ?? true else { return .allow }

        var newURL: URL?

        // 2. De-AMP.
        if settings.deAMP, let canonical = NavigationGuard.deAMP(newURL ?? url) {
            newURL = canonical
        }

        // 3. Strip tracking parameters.
        if settings.stripTrackingParams, let cleaned = NavigationGuard.strippingTrackingParams(from: newURL ?? url) {
            newURL = cleaned
        }

        // 4. HTTPS-Only upgrade (skip hosts the user explicitly allowed and raw IPs/localhost).
        let effective = newURL ?? url
        if settings.httpsOnly,
           effective.scheme?.lowercased() == "http",
           let host = effective.host?.lowercased(),
           !httpAllowedHosts.contains(host),
           host != "localhost", !host.hasSuffix(".local"), IPv4(host) == false {
            var comps = URLComponents(url: effective, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            if let upgraded = comps?.url {
                upgradedURLs[upgraded.absoluteString] = effective
                newURL = upgraded
            }
        }

        // 5. GPC header on main-frame GETs (re-issue once per URL; POSTs are never re-issued).
        let isGET = (action.request.httpMethod ?? "GET").uppercased() == "GET"
        let hasGPC = action.request.value(forHTTPHeaderField: "Sec-GPC") == "1"
        let target = newURL ?? url
        let wantsGPCReissue = settings.gpcSignal && isGET && !hasGPC
            && !gpcHandled.contains(target.absoluteString)

        if newURL == nil && !wantsGPCReissue {
            model?.applyPerSiteShields(for: target)
            return .allow
        }
        guard isGET else {  // never rewrite a POST — allow it unmodified
            model?.applyPerSiteShields(for: url)
            return .allow
        }

        var request = URLRequest(url: target)
        if settings.gpcSignal {
            request.setValue("1", forHTTPHeaderField: "Sec-GPC")
            gpcHandled.insert(target.absoluteString)
            if gpcHandled.count > 400 { gpcHandled.removeAll() }  // bound the loop-guard set
        }
        webView.load(request)
        return .cancel
    }

    private func IPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - HTTPS-Only fallback

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        MainActor.assumeIsolated {
            handleLoadFailure(webView, error: error)
        }
    }

    private func handleLoadFailure(_ webView: WKWebView, error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        // WebKit reports "Frame load interrupted" (102) for downloads/handed-off loads — not an error.
        guard !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }

        // If this was our silent http→https upgrade, offer the plain-HTTP fallback.
        let failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if let failed = failedURL, let original = upgradedURLs.removeValue(forKey: failed.absoluteString) {
            model?.offerHTTPFallback(to: original)
            return
        }

        // Otherwise: a real dead end (offline, DNS, TLS…) → native error page.
        model?.loadError = nsError.localizedDescription
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.loadError = nil }
    }

    // MARK: - Downloads

    /// Decide whether a response should be shown or downloaded. Attachments (Content-Disposition) and
    /// content the web view can't render (zips, dmgs, installers, …) become downloads instead of a
    /// blank page or a "can't display" dead end.
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated {
            if Self.shouldDownload(navigationResponse) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return true
        }
        // The web view can't display this MIME type (a real main-frame resource, not a subframe embed).
        return response.isForMainFrame && !response.canShowMIMEType
    }

    /// A navigation (e.g. a "download" link) turned into a download — hand it to the manager.
    nonisolated func webView(_ webView: WKWebView,
                             navigationAction: WKNavigationAction,
                             didBecome download: WKDownload) {
        MainActor.assumeIsolated {
            download.delegate = DownloadManager.shared.begin(download)
        }
    }

    /// A response we chose to download became a WKDownload — hand it to the manager.
    nonisolated func webView(_ webView: WKWebView,
                             navigationResponse: WKNavigationResponse,
                             didBecome download: WKDownload) {
        MainActor.assumeIsolated {
            download.delegate = DownloadManager.shared.begin(download)
        }
    }

    /// The WebContent process was terminated (memory pressure or a page bug). Without this the tab
    /// sits blank forever — reload it in place so it recovers itself.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            model?.recoverFromWebContentCrash()
        }
    }

}
