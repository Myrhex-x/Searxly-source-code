//
//  PhishingGuard.swift
//  Searxly
//
//  A privacy-preserving warning for known-malicious sites. Deliberately NOT Google Safe Browsing —
//  that phones every URL you visit home, which is exactly what Searxly refuses to do. Instead this
//  checks the destination host against a BUNDLED, offline blocklist (the same model as the uBlock
//  filter lists), so nothing about your browsing ever leaves the device.
//
//  Honest scope: the bundled list is only as good as what it's populated with. It ships seeded with
//  the standard AV/phishing TEST domains (wicar.org, Google's Safe Browsing test host) so the guard
//  is demonstrably live, and is meant to be filled from an offline feed (URLhaus / PhishTank) at
//  build time. It is a safety net for KNOWN-bad hosts, not a heuristic that catches novel phishing —
//  the homograph display + registrable-domain emphasis (DomainSafety) cover the "looks like a real
//  site" angle; this covers the "is a known-bad site" angle.
//

import Foundation

enum PhishingGuard {

    private static let key = "Safety.PhishingGuard"

    /// On by default — it only ever warns (with an override), and never phones home.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Fragment marker the interstitial's "Continue anyway" appends, so the navigation delegate can
    /// tell "the user chose to proceed" from a normal navigation without a message-handler round-trip.
    static let proceedFragment = "__searxly_proceed_unsafe"

    /// Known-malicious hosts (exact host or registrable domain). Seeded with deliberate TEST domains
    /// that exist specifically to trigger this kind of protection; populate from an offline feed to
    /// make it comprehensive.
    static let blockedHosts: Set<String> = [
        "wicar.org",                       // AV test site with deliberate test malware
        "testsafebrowsing.appspot.com",    // Google Safe Browsing test host
        "malware.testing.google.test",     // reserved malware test name
        "phishing.testing.google.test",    // reserved phishing test name
    ]

    /// Whether a navigation to `url` should be warned about: its host, or the host's registrable
    /// domain, is on the blocklist. Only http(s) — other schemes never reach here.
    static func isBlocked(_ url: URL) -> Bool {
        guard isEnabled, let host = url.host?.lowercased() else { return false }
        if blockedHosts.contains(host) { return true }
        if let registrable = DomainSafety.registrableDomain(host), blockedHosts.contains(registrable) {
            return true
        }
        return false
    }

    /// The full-page warning shown in place of a blocked site. "Go Back" returns to the previous page;
    /// "Continue anyway" re-navigates to the same URL with `proceedFragment`, which the delegate reads
    /// as consent and allows (once, for that host).
    static func interstitialHTML(for url: URL, host: String) -> String {
        let safeHost = DomainSafety.displayHost(forHost: host)
        let target = url.absoluteString
        let proceedURL = url.absoluteString + (url.fragment == nil ? "#" : "&") + proceedFragment
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark; }
          html,body { height:100%; margin:0; }
          body { background:#0a0a0c; color:#e8e8ea; font:15px -apple-system,system-ui,sans-serif;
                 display:flex; align-items:center; justify-content:center; }
          .card { max-width:440px; padding:36px 34px; text-align:center; }
          .mark { width:56px; height:56px; border-radius:14px; margin:0 auto 20px;
                  background:rgba(255,90,90,0.12); border:1px solid rgba(255,90,90,0.4);
                  display:flex; align-items:center; justify-content:center; font-size:28px; }
          h1 { font-size:19px; font-weight:700; margin:0 0 10px; }
          p { font-size:13.5px; line-height:1.55; color:#b6b6bb; margin:0 0 8px; }
          .host { font-weight:600; color:#e8e8ea; word-break:break-all; }
          .actions { margin-top:26px; display:flex; flex-direction:column; gap:10px; }
          a.btn { display:block; padding:11px 16px; border-radius:10px; text-decoration:none;
                  font-size:13.5px; font-weight:600; }
          .primary { background:#f2f2f4; color:#0a0a0c; }
          .danger { color:#ff6b6b; border:1px solid rgba(255,90,90,0.35); }
          .fine { font-size:11.5px; color:#77777c; margin-top:16px; }
        </style></head>
        <body><div class="card">
          <div class="mark">⚠️</div>
          <h1>Warning: this site may be dangerous</h1>
          <p><span class="host">\(safeHost)</span> is on Searxly's list of known malicious or
             deceptive sites. It may try to steal your information or harm your device.</p>
          <p>This check runs entirely on your device — nothing about your browsing was sent anywhere.</p>
          <div class="actions">
            <a class="btn primary" href="#" onclick="if(history.length>1){history.back()}else{location.replace('about:blank')};return false;">Go Back (recommended)</a>
            <a class="btn danger" href="\(proceedURL)">Continue anyway — I understand the risk</a>
          </div>
          <div class="fine">Destination: \(target)</div>
        </div></body></html>
        """
    }
}
