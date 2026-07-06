//
//  WebViewRepresentable+Navigation.swift
//  Searxly
//
//  WKNavigationDelegate methods and certificate handling for WebViewRepresentable.Coordinator.
//

import WebKit
import os

extension WebViewRepresentable.Coordinator {
    /// Onion tabs are proxy-only: their data store carries a SOCKS5 proxy configuration. We never let
    /// a navigation leave that path — only http(s) (carried by the proxy) and our local placeholder
    /// schemes are allowed; anything else (custom schemes, file:, etc.) is cancelled. Non-onion tabs
    /// are unaffected (always allowed). Detected via the presence of a proxy on the data store, so no
    /// per-tab plumbing is needed.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isOnionTab = !webView.configuration.websiteDataStore.proxyConfigurations.isEmpty
        if isOnionTab {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            let allowed: Set<String> = ["http", "https", "about", "data", "blob"]
            if !allowed.contains(scheme) {
                decisionHandler(.cancel)
                return
            }
        }
        // Maximum-Privacy kill switch (fail closed): block non-loopback web egress while the chosen
        // protection network (VPN/Tor) isn't verified up, and show the blocked page. Loopback (the
        // local SearXNG UI / new-tab page) stays allowed. Kicks a connection attempt so it self-heals.
        if PrivacyGate.shared.shouldBlockWebNavigation(to: navigationAction.request.url) {
            if navigationAction.targetFrame?.isMainFrame ?? true {
                lastBlockedURL = navigationAction.request.url
                let reason = PrivacyGate.shared.blockReason ?? "Maximum Privacy is on, but protection isn't active yet."
                webView.loadHTMLString(Self.protectionBlockedHTML(reason: reason),
                                       baseURL: navigationAction.request.url)
                Task { await PrivacyGate.shared.ensureProtection() }
            }
            decisionHandler(.cancel)
            return
        }
        // ⌘-click a link → open it in a new tab (background by default, foreground with ⇧ held),
        // matching Safari. Only for genuine link clicks on http(s), and never on onion tabs (a new
        // standard tab would leave Tor and deanonymize the request).
        if !isOnionTab,
           navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let foreground = navigationAction.modifierFlags.contains(.shift)
            NotificationCenter.default.post(
                name: .openURLInNewTab,
                object: url,
                userInfo: ["background": !foreground]
            )
            decisionHandler(.cancel)
            return
        }
        // Links explicitly marked for download (e.g. <a download>) save to disk instead of navigating.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    /// Onion-Location auto-detect: when a normal page's response carries an `Onion-Location` header
    /// pointing at a `.onion` mirror, surface an offer to switch. Skipped on onion tabs themselves.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           webView.configuration.websiteDataStore.proxyConfigurations.isEmpty,   // not already an onion tab
           let http = navigationResponse.response as? HTTPURLResponse,
           let raw = http.value(forHTTPHeaderField: "Onion-Location"),
           let onion = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           onion.isOnionService {
            let host = http.url?.host ?? webView.url?.host ?? ""
            NotificationCenter.default.post(
                name: .onionLocationDetected, object: nil,
                userInfo: ["onion": onion.absoluteString, "host": host]
            )
        }
        // Anything WebKit can't render inline (zip, dmg, pkg, …) or that the server marks as an
        // attachment is saved to the user's Downloads folder via WKDownload. Onion tabs included —
        // the bytes ride the same Tor proxy as the page.
        if Self.shouldDownload(navigationResponse) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    /// Whether a response should be saved to disk instead of displayed: true when WebKit cannot show
    /// the MIME type inline, or the server explicitly marks the body as an attachment.
    static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        if !navigationResponse.canShowMIMEType { return true }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return true
        }
        return false
    }

    /// A navigation turned into a download (server sent an attachment / non-displayable body).
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { DownloadBridge.shared.begin(download) }
    }

    /// A navigation action turned into a download (e.g. an <a download> link).
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { DownloadBridge.shared.begin(download) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { self.parent.isLoading = true }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.observedContainer?.stabilizeLayout(repeats: 2)
            self.parent.requestStabilization()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { self.parent.isLoading = false }
        if DeveloperSettings.shared.isEnabled {
            Log.web.info("[AdBlock] Page finished loading: \(webView.url?.absoluteString ?? "unknown")")
        }

        DispatchQueue.main.async {
            self.observedContainer?.stabilizeLayout(repeats: 3)
            self.parent.requestStabilization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let js = """
            (function(){
              try {
                const h = Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight || 0);
                if (h < 80) {
                  window.dispatchEvent(new Event('resize'));
                  const de = document.documentElement;
                  const old = de.style.width;
                  const w = window.innerWidth || 800;
                  de.style.width = (w + 0.6) + 'px';
                  void de.offsetWidth;
                  de.style.width = old || '100%';
                  void de.offsetWidth;
                  window.dispatchEvent(new Event('resize'));
                }
              } catch(e){}
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            self.observedContainer?.stabilizeLayout(repeats: 1)
        }

        if let u = webView.url {
            let settledTitle = webView.title ?? ""
            NotificationCenter.default.post(
                name: BrowserState.historyTitleSnapshotNotification,
                object: nil,
                userInfo: ["url": u, "title": settledTitle]
            )
        }

        // Onion-Location auto-detect (meta-tag fallback; the response header is handled in
        // decidePolicyFor navigationResponse). Skipped on onion tabs.
        if webView.configuration.websiteDataStore.proxyConfigurations.isEmpty {
            let pageHost = webView.url?.host ?? ""
            let onionMetaJS = """
            (function(){var m=document.querySelector("meta[http-equiv='onion-location' i]");return m?m.content:"";})()
            """
            webView.evaluateJavaScript(onionMetaJS) { result, _ in
                guard let s = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !s.isEmpty, let onion = URL(string: s), onion.isOnionService else { return }
                NotificationCenter.default.post(
                    name: .onionLocationDetected, object: nil,
                    userInfo: ["onion": onion.absoluteString, "host": pageHost]
                )
            }
        }

        if let url = webView.url, (url.host?.contains("youtube.com") == true || url.host?.contains("youtu.be") == true) {
            enterYouTubeSafeMode(on: webView)
            YouTubeAdBlocker.shared.reapplyProtection(on: webView)

            if DeveloperSettings.shared.youTubeCompatibilityMode {
                webView.configuration.userContentController.removeAllUserScripts()
            }

            if isYouTubeVideoPage(url) {
                let ytCleanup = """
                (function() {
                    'use strict';
                    try {
                        const toHide = [
                            'ytd-ad-slot-renderer', 'ytd-promoted-sparkles-web-renderer', '#player-ads',
                            '#masthead-ad', '[data-ad-slot]',
                            '.ytp-ad-overlay-container',
                            'ytd-enforcement-message-view-model', '.ytp-error', 'yt-mealbar-promo-renderer',
                            'ytd-player-error-message-renderer', '[class*="enforcement"]',
                            'ytd-ad-overlay-renderer'
                        ];
                        toHide.forEach(sel => {
                            document.querySelectorAll(sel).forEach(el => {
                                const core = el.closest('ytd-player, #player, .html5-video-player, .html5-video-container, #movie_player') ||
                                             el.querySelector('video') || (el.tagName === 'VIDEO');
                                if (core) {
                                    try {
                                        el.style.setProperty('display', 'block', 'important');
                                        el.style.setProperty('visibility', 'visible', 'important');
                                        el.style.setProperty('opacity', '1', 'important');
                                    } catch(_) {}
                                    return;
                                }
                                el.style.cssText = 'display:none !important; visibility:hidden !important; opacity:0 !important; pointer-events:none !important;';
                                if (el.parentNode) {
                                    try { el.parentNode.removeChild(el); } catch(_) {}
                                }
                            });
                        });

                        const skipButtons = document.querySelectorAll(
                            '.ytp-ad-skip-button, .ytp-skip-ad-button, ' +
                            'button[aria-label*="Skip"], .ytp-ad-skip-button-modern, ' +
                            '[class*="skip-ad"], [class*="ad-skip"]'
                        );
                        skipButtons.forEach(btn => {
                            if (btn && btn.offsetParent !== null) {
                                try { btn.click(); btn.dispatchEvent(new MouseEvent('click', {bubbles:true})); } catch(_) {}
                            }
                        });

                        const playerContainers = document.querySelectorAll(
                            'ytd-player, #player, .html5-video-player, .html5-video-container, #player-container, #movie_player'
                        );
                        playerContainers.forEach(p => {
                            p.style.setProperty('display', 'block', 'important');
                            p.style.setProperty('visibility', 'visible', 'important');
                            p.style.setProperty('opacity', '1', 'important');
                            p.style.setProperty('min-width', '640px', 'important');
                            p.style.setProperty('width', '100%', 'important');
                        });

                        const videos = document.querySelectorAll('video');
                        videos.forEach(v => {
                            v.style.setProperty('display', 'block', 'important');
                            v.style.setProperty('visibility', 'visible', 'important');
                            v.style.setProperty('opacity', '1', 'important');
                        });
                    } catch(e) {}
                })();
                """
                webView.evaluateJavaScript(ytCleanup, completionHandler: nil)

                let delays: [TimeInterval] = [0.4, 0.9, 1.4, 2.0, 3.0, 4.5, 6.5]
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                        webView?.evaluateJavaScript(ytCleanup, completionHandler: nil)
                    }
                }

                youtubeHighFreqSource?.cancel()
                var intervalCount = 0
                let src: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: .main)
                src.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300), leeway: .milliseconds(60))
                src.setEventHandler { [weak webView] in
                    intervalCount += 1
                    guard let wv = webView else { src.cancel(); return }
                    if intervalCount > 26 {
                        src.cancel()
                        return
                    }
                    wv.evaluateJavaScript("(document.querySelectorAll('video').length > 0 && Array.from(document.querySelectorAll('video')).some(v => (v.videoWidth||0) >= 640))", completionHandler: { result, _ in
                        if let good = result as? Bool, good {
                            wv.evaluateJavaScript(ytCleanup, completionHandler: nil)
                            src.cancel()
                            return
                        }
                    })
                    wv.evaluateJavaScript(ytCleanup, completionHandler: nil)
                }
                youtubeHighFreqSource = src
                src.resume()

                let observerJS = """
                (function() {
                    if (window.__searxlyYTForcePlay) return;
                    window.__searxlyYTForcePlay = true;

                    const doNuke = () => {
                        const bad = document.querySelectorAll(
                            'ytd-enforcement-message-view-model, .ytp-error, [class*="enforcement"], ' +
                            'ytd-ad-slot-renderer, .ytp-ad-overlay-container, #masthead-ad, #player-ads'
                        );
                        bad.forEach(el => {
                            const core = el.closest('ytd-player, #player, .html5-video-player, .html5-video-container, #movie_player') ||
                                         el.querySelector('video') || (el.tagName === 'VIDEO');
                            if (core) {
                                try {
                                    el.style.setProperty('display', 'block', 'important');
                                    el.style.setProperty('visibility', 'visible', 'important');
                                    el.style.setProperty('opacity', '1', 'important');
                                } catch(_) {}
                                return;
                            }
                            el.style.cssText = 'display:none!important;visibility:hidden!important;';
                            if (el.parentNode) try { el.parentNode.removeChild(el); } catch(_) {}
                        });
                        document.querySelectorAll('video').forEach(v => {
                            v.style.setProperty('display','block','important');
                            v.style.setProperty('visibility','visible','important');
                            v.style.setProperty('opacity','1','important');
                        });
                    };

                    const obs = new MutationObserver(doNuke);
                    obs.observe(document.documentElement || document.body, { childList: true, subtree: true });

                    doNuke(); setTimeout(doNuke, 400); setTimeout(doNuke, 900);
                    setTimeout(() => { try { obs.disconnect(); } catch(_) {} }, 12000);
                })();
                """
                webView.evaluateJavaScript(observerJS, completionHandler: nil)

                startYouTubeRecoveryTimer()

                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak webView] in
                    webView?.evaluateJavaScript("""
                    (function(){
                      try {
                        const vids = Array.from(document.querySelectorAll('video'));
                        const info = vids.map(v => ({ w: v.videoWidth||0, h: v.videoHeight||0, ready: v.readyState, src: (v.currentSrc||'').slice(0,120) }));
                        console.log('[YT Quality]', info);
                        return info;
                      } catch(e){ return null; }
                    })();
                    """, completionHandler: { res, _ in
                        if DeveloperSettings.shared.isEnabled || DeveloperSettings.shared.verboseTabLifecycleLogging {
                            Log.web.debug("[YT Quality] video natural sizes after settle: \(String(describing: res ?? "n/a"), privacy: .public)")
                        }
                    })
                }
            } else {
                stopYouTubeRecoveryTimer()
                youtubeHighFreqSource?.cancel()
                youtubeHighFreqSource = nil
            }
        } else {
            stopYouTubeRecoveryTimer()
            youtubeHighFreqSource?.cancel()
            youtubeHighFreqSource = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.parent.isLoading = false
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
                Log.web.error("[Dev] WebView error: \(error.localizedDescription)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async {
            self.parent.isLoading = false
            if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.verboseTabLifecycleLogging {
                Log.web.error("[Dev] WebView provisional navigation failed: \(error.localizedDescription) for \(webView.url?.absoluteString ?? "unknown")")
            }
            self.observedContainer?.stabilizeLayout(repeats: 1)

            // Onion tabs: when a real load fails (onion offline/unreachable), show a friendly page
            // rather than a blank failure. Ignore NSURLErrorCancelled — that fires when the
            // "Connecting to Tor…" placeholder is replaced by the real load, and isn't an error.
            let isOnionTab = !webView.configuration.websiteDataStore.proxyConfigurations.isEmpty
            let nsErr = error as NSError
            if isOnionTab, !(nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled) {
                let host = webView.url?.host ?? "this hidden service"
                webView.loadHTMLString(Self.onionErrorHTML(host: host), baseURL: webView.url)
                if let h = webView.url?.host {
                    NotificationCenter.default.post(name: .onionUnreachable, object: nil, userInfo: ["host": h])
                }
            }
        }
    }

    /// The page's WebContent (renderer) process died — out-of-memory, a renderer crash, or the WebKit
    /// sandbox terminating it. Without intervention the tab is left blank/white until the user manually
    /// reloads. We reload once, rate-limited, so a page that deterministically crashes its renderer can't
    /// spin in an endless reload loop (which would be worse than a blank tab).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if let last = lastWebContentCrashReload, now.timeIntervalSince(last) < 10 {
            Log.web.error("WebContent process terminated again within 10s — not auto-reloading to avoid a crash loop.")
            return
        }
        lastWebContentCrashReload = now
        Log.web.notice("WebContent process terminated — auto-reloading the tab.")
        DispatchQueue.main.async {
            if webView.url != nil {
                webView.reload()
            } else if let item = webView.backForwardList.currentItem {
                // Crashed before a URL committed (e.g. during first load): restore from history if we can.
                webView.go(to: item)
            }
        }
    }

    /// Friendly monochrome error page for an unreachable / offline onion service.
    static func onionErrorHTML(host: String) -> String {
        let safeHost = host.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          html,body{height:100%;margin:0}
          body{display:flex;align-items:center;justify-content:center;
               font:-apple-system-body,-apple-system,system-ui,sans-serif;background:#fff;color:#111}
          @media (prefers-color-scheme: dark){ body{background:#0a0a0a;color:#f2f2f2} }
          .card{max-width:440px;padding:32px;text-align:center}
          .glyph{font-size:30px;opacity:.8;margin-bottom:16px}
          h1{font-size:18px;font-weight:600;margin:0 0 8px}
          p{font-size:13px;line-height:1.5;opacity:.7;margin:0 0 6px}
          code{font-size:11px;opacity:.6;word-break:break-all}
        </style></head>
        <body><div class="card">
          <div class="glyph">⚠️</div>
          <h1>Can’t reach this onion service</h1>
          <p>Tor connected, but the hidden service didn’t respond. It may be offline, overloaded, or
          the address may be wrong.</p>
          <p>Try reloading — Tor will attempt a fresh route.</p>
          <p><code>\(safeHost)</code></p>
        </div></body></html>
        """
    }

    /// Protection (VPN/Tor) state changed. If a navigation was blocked while protection was down and
    /// it's now restored, reload the page that was blocked.
    @objc func protectionStateChanged() {
        guard let url = lastBlockedURL, !PrivacyGate.shared.shouldBlockWebNavigation(to: url) else { return }
        lastBlockedURL = nil
        observedWebView?.load(URLRequest(url: url))
    }

    /// Friendly monochrome page shown when the Maximum-Privacy kill switch blocks a navigation because
    /// the chosen protection network isn't up. Mirrors onionErrorHTML's styling. Includes a captive-
    /// portal escape hint (some networks need a sign-in page the kill switch would otherwise block).
    static func protectionBlockedHTML(reason: String) -> String {
        let safe = reason.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          :root { color-scheme: light dark; }
          html,body{height:100%;margin:0}
          body{display:flex;align-items:center;justify-content:center;
               font:-apple-system-body,-apple-system,system-ui,sans-serif;background:#fff;color:#111}
          @media (prefers-color-scheme: dark){ body{background:#0a0a0a;color:#f2f2f2} }
          .card{max-width:460px;padding:32px;text-align:center}
          .glyph{font-size:30px;opacity:.85;margin-bottom:16px}
          h1{font-size:18px;font-weight:600;margin:0 0 8px}
          p{font-size:13px;line-height:1.5;opacity:.7;margin:0 0 10px}
          .hint{font-size:11px;opacity:.55;margin-top:14px}
        </style></head>
        <body><div class="card">
          <div class="glyph">🛡️</div>
          <h1>Traffic blocked to protect you</h1>
          <p>Maximum Privacy hides your IP behind a VPN or Tor. Until that connection is up, Searxly
          won't load this page — so your real IP can't leak.</p>
          <p>\(safe)</p>
          <p class="hint">This page reloads automatically once protection is active. If you just joined
          a Wi-Fi network that needs a sign-in page, switch to Normal mode to sign in, then return to
          Maximum Privacy.</p>
        </div></body></html>
        """
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only bypass certificate validation for unambiguous LOOPBACK addresses, which a network
        // attacker cannot intercept. The bundled local SearXNG runs over HTTP on 127.0.0.1, so this
        // only matters for a user-run HTTPS service on loopback with a self-signed cert.
        //
        // We deliberately do NOT bypass for ".local" (mDNS) anymore: any host on the LAN can claim a
        // ".local" name, so trusting those unconditionally was a LAN-MITM hole. (Earlier still, a
        // `host.contains("searx")` check trusted any attacker domain containing "searx".)
        if let serverTrust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host.lowercased()
            let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            if isLoopback {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

extension WebViewRepresentable.Coordinator: WKUIDelegate {
    /// Routes new-window requests — `target="_blank"`, `window.open()`, and the context menu's
    /// "Open Link in New Tab" — into a real Searxly tab. Returning nil (after opening our own tab)
    /// tells WebKit not to spawn a window. Without this method WKWebView silently drops these links.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NotificationCenter.default.post(name: .openURLInNewTab, object: url)
        }
        return nil
    }

    /// Enforces the user's per-site camera/microphone choices (set in the address-bar privacy popover).
    /// `.ask` falls through to `.prompt` so WebKit shows its own request — identical to default behavior
    /// until the user explicitly Allows or Blocks a site.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host
        let result: WKPermissionDecision = MainActor.assumeIsolated {
            let store = SitePermissionStore.shared
            func map(_ decision: SitePermissionDecision) -> WKPermissionDecision {
                switch decision {
                case .allow: return .grant
                case .block: return .deny
                case .ask:   return .prompt
                }
            }
            switch type {
            case .camera:
                return map(store.decision(.camera, for: host))
            case .microphone:
                return map(store.decision(.microphone, for: host))
            case .cameraAndMicrophone:
                let camera = store.decision(.camera, for: host)
                let mic = store.decision(.microphone, for: host)
                if camera == .block || mic == .block { return .deny }
                if camera == .allow && mic == .allow { return .grant }
                return .prompt
            @unknown default:
                return .prompt
            }
        }
        decisionHandler(result)
    }
}