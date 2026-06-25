//
//  WebViewFactory.swift
//  Searxly
//
//  Created for clean separation of WebKit configuration and privacy modes.
//  All logic for creating standard vs private/ephemeral WKWebView instances lives here.
//

import WebKit
import os
import Network   // ProxyConfiguration / NWEndpoint — SOCKS5 proxy for onion tabs (macOS 14+)

/// Represents the privacy level of a browser tab.
/// - .standard: Normal persistent cookies, storage, and cache (default)
/// - .privateEphemeral: Uses a non-persistent WKWebsiteDataStore. Nothing is written to disk.
///   The data is discarded when the WKWebView (and its data store) is deallocated.
///
/// FUTURE: Per-site exception list for "Allow persistent storage even in Private tabs".
/// This can be implemented by:
/// 1. Adding a simple Codable list of hosts in AppData / Persistence.
/// 2. In the WKNavigationDelegate (WebViewRepresentable.Coordinator), inspect
///    navigationAction.request.url.host and decide whether to use a persistent
///    data store for that specific navigation (advanced — requires more WKWebView
///    configuration swapping or custom URLSchemeHandler tricks).
enum TabPrivacyMode: String, CaseIterable, Codable {
    case standard
    case privateEphemeral
    /// Onion tab: ephemeral data store routed through the bundled Tor client's SOCKS5 proxy so
    /// `.onion` hidden services are reachable and the real IP is hidden. See TorManager.
    case onion

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .privateEphemeral: return "Private"
        case .onion: return "Tor"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "globe"
        case .privateEphemeral: return "shield.fill"
        case .onion: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Central factory for creating WKWebView instances with appropriate privacy configuration.
/// Keeping this logic in one place makes future hardening, feature flags, and testing much easier.
///
/// NOTE: This file uses a small number of private KVC calls on WKPreferences (documented inline).
/// These are used only for fingerprinting reduction and Web Inspector support.
struct WebViewFactory {

    // NOTE: WKProcessPool no longer provides process isolation (deprecated since macOS 12 / WebKit change).
    // Real private tab isolation comes from using WKWebsiteDataStore.nonPersistent() below.
    // We keep a single default process pool for all tabs.

    /// Creates a new WKWebView configured according to the requested privacy mode.
    /// Each call to .privateEphemeral gets its own isolated non-persistent data store
    /// and uses a separate WKProcessPool from standard tabs.
    @MainActor
    static func makeWebView(mode: TabPrivacyMode) -> WKWebView {
        // Must be on main thread — WKWebView and friends (WKWebpagePreferences etc.) require it.
        // This turns future cross-actor creation bugs (e.g. from @Sendable AI tool callbacks)
        // into an immediate, clear assertion instead of an opaque EXC_BREAKPOINT deep inside WebKit.
        precondition(Thread.isMainThread, "WebViewFactory.makeWebView must be called on the main thread (called from non-main context in AI tool path or similar)")

        let configuration = WKWebViewConfiguration()

        // Common sensible defaults for a privacy-oriented browser
        // JavaScript control moved to WKWebpagePreferences in modern WebKit
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePrefs

        configuration.allowsAirPlayForMediaPlayback = false
        // Fully allow media playback without requiring user gesture.
        // This is part of "make videos work on YouTube". YouTube's player expects to be able
        // to start (often muted) programmatically.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Additional media friendliness for WKWebView on macOS (helps with YouTube and other video sites).
        // Note: allowsInlineMediaPlayback is iOS-only; on macOS we rely on mediaTypesRequiringUserActionForPlayback = []
        // and other settings. isElementFullscreenEnabled helps with modern player features.
        if #available(macOS 12.0, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        // === Private API / KVC usage (documented risks) ===
        //
        // These use private keys on WKPreferences. They are not guaranteed to work
        // forever and can break on WebKit updates. They are only used for:
        //   - Reducing fingerprinting surface
        //   - Enabling Web Inspector for developers (when explicitly requested)
        //
        // We accept the fragility because there is currently no public API for these behaviors.

        // Reduce some common WebRTC / media device fingerprinting vectors.
        // Private key — may stop working in future WebKit versions.
        configuration.preferences.setValue(false, forKey: "mediaDevicesEnabled")

        // Disable some automatic behaviors that can leak state
        configuration.suppressesIncrementalRendering = false

        // Developer Mode: Enable Safari Web Inspector (right-click → Inspect Element)
        // This is the only practical way to expose Web Inspector for WKWebView on macOS
        // outside the App Store. Only active when the user has explicitly turned on
        // Developer Mode + the Web Inspector toggle.
        if DeveloperSettings.shared.isEnabled && DeveloperSettings.shared.webInspectorEnabled {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }

        // Apply general ad & tracker blocking (network + cosmetic).
        AdBlockManager.shared.apply(to: configuration)

        // Dedicated YouTube ad blocker / skipper (separate module).
        // Injected for every webview; the script itself early-returns off youtube.com.
        // This gives us YT-specific, well-tested logic (instant-skip on ad state, strong
        // enforcement bypass, player protection) without polluting the general adblocker.
        YouTubeAdBlocker.shared.apply(to: configuration)

        // === Layout & Viewport Quality Fixer ===
        // Injected at document start (same timing as adblock scripts) so it runs before the page's
        // own <head> parsing and any early JS that measures window dimensions, sets up canvas,
        // or decides layout based on media queries / 100vw etc.
        //
        // This is the highest-leverage piece for the "page is entirely widened / super wide"
        // class of bugs (speedtest, certain dashboards, canvas apps, etc.) when the WKWebView
        // lives in a SwiftUI sidebar-constrained pane instead of a full desktop window.
        //
        // The script:
        //   - Guarantees a proper viewport meta (width=device-width + sane scales + shrink-to-fit)
        //   - Adds a minimal defensive max-width on html/body (does not fight legitimate designs)
        //   - Schedules resize dispatches + reflow forces on DOMContentLoaded + load
        //
        // Additional runtime stabilization is provided by WebViewContainer (layout() + explicit calls)
        // and WebViewRepresentable.Coordinator (didCommit / didFinish).
        let layoutFixerScript = WKUserScript(
            source: Self.layoutFixerSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(layoutFixerScript)

        // === Wallet provider (EIP-1193 / EIP-6963) ===
        // Privacy: only inject window.ethereum when a wallet exists, the user hasn't disabled site
        // exposure, AND this is a standard (non-private) tab. Private tabs never expose the wallet,
        // so a site there can't link the private session to your wallet identity. Users without a
        // wallet leak NO wallet fingerprint to any site.
        let walletConfigured = UserDefaults.standard.bool(forKey: WalletConfig.Keys.walletConfigured)
        if mode == .standard && walletConfigured && WalletFeatures.dappProvider {
            // Bake the wallet's current chain into the injected provider (read from persisted prefs
            // to avoid an actor hop here). Later chain switches are pushed via `chainChanged`.
            let injectChain = WalletChain.by(id: UserDefaults.standard.integer(forKey: WalletConfig.Keys.activeChain)) ?? .defaultChain
            let walletProviderScript = WKUserScript(
                source: WalletProviderScript.source(chainIdHex: injectChain.chainIdHex,
                                                    networkVersion: String(injectChain.id)),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(walletProviderScript)
        }

        switch mode {
        case .standard:
            // Default behavior: persistent website data store (cookies, localStorage, cache survive)
            // Give standard tabs a clean, identifiable UA suffix as well (helps some sites and debugging).
            if configuration.applicationNameForUserAgent == nil {
                configuration.applicationNameForUserAgent = "Searxly/1.0"
            }
            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            return webView

        case .privateEphemeral:
            // Fresh non-persistent data store for this tab only.
            // Data is never written to disk and is released when the webview is destroyed.
            let ephemeralDataStore = WKWebsiteDataStore.nonPersistent()
            configuration.websiteDataStore = ephemeralDataStore

            // (Process pool separation is no longer effective per Apple; the non-persistent
            // WKWebsiteDataStore below is what actually keeps Private tab data isolated and in-memory only.)

            // Extra hardening that only makes sense for ephemeral sessions
            configuration.applicationNameForUserAgent = "Searxly/1.0 (Private)"

            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            return webView

            // FUTURE (per-site exceptions): When we have a host allow-list,
            // we can decide here (or in the navigation delegate) to swap in
            // the default persistent store for specific hosts even inside a
            // nominally "Private" tab.

        case .onion:
            // Onion tab: a fresh non-persistent data store (like Private) whose traffic is routed
            // through the bundled Tor client's local SOCKS5 endpoint. SOCKS5h semantics mean the
            // hostname — including .onion — is resolved at the proxy, so .onion services become
            // reachable and there is no DNS leak.
            //
            // NOTE: Tor must be bootstrapped before navigations are issued into this view. The
            // routing path (BrowserState.openOnionURL) awaits TorManager.ensureReadyAndRunning()
            // before loading the URL.
            let onionStore = WKWebsiteDataStore.nonPersistent()
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(TorRuntimeConfig.socksHost),
                port: NWEndpoint.Port(rawValue: TorRuntimeConfig.socksPort) ?? 19050
            )
            onionStore.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
            configuration.websiteDataStore = onionStore

            // Leak hardening: neuter WebRTC (the classic IP-leak vector) + deny geolocation in every
            // frame, at document start so it wins the race against page scripts.
            let hardening = WKUserScript(source: Self.onionHardeningSource,
                                         injectionTime: .atDocumentStart,
                                         forMainFrameOnly: false)
            configuration.userContentController.addUserScript(hardening)

            // Uniform user agent: deliberately leave applicationNameForUserAgent UNSET so onion tabs
            // send the default Safari-like UA with no "Searxly"/"Private" suffix that would single
            // them out. (Honest scope: this reduces — not eliminates — fingerprinting; not Tor Browser.)

            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            return webView
        }
    }

    /// Injected into onion tabs at document start. Removes the highest-signal IP-leak vectors that
    /// WKWebView still exposes: WebRTC peer connections / media-device enumeration, and geolocation.
    /// This is defense-in-depth on top of network routing — NOT full Tor Browser fingerprint defense.
    static let onionHardeningSource: String = """
    (function(){
        'use strict';
        try {
            ['RTCPeerConnection','webkitRTCPeerConnection','mozRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate'].forEach(function(k){
                try { Object.defineProperty(window, k, { value: undefined, configurable: false, writable: false }); } catch(e){}
            });
            if (navigator.mediaDevices) {
                try { navigator.mediaDevices.getUserMedia = function(){ return Promise.reject(new DOMException('Disabled in Tor tab','NotAllowedError')); }; } catch(e){}
                try { navigator.mediaDevices.enumerateDevices = function(){ return Promise.resolve([]); }; } catch(e){}
            }
        } catch(e){}
        try {
            if (navigator.geolocation) {
                var deny = function(_success, error){ if (typeof error === 'function') { try { error({ code: 1, message: 'Geolocation disabled in Tor tab', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 }); } catch(e){} } };
                navigator.geolocation.getCurrentPosition = deny;
                navigator.geolocation.watchPosition = function(){ return 0; };
                navigator.geolocation.clearWatch = function(){};
            }
        } catch(e){}
        // Reduce the timezone fingerprint: report UTC. (Covers the common checks — Intl + offset —
        // without rewriting Date's local-time methods, which would break legitimate time display.)
        try {
            Date.prototype.getTimezoneOffset = function(){ return 0; };
            var _resolved = Intl.DateTimeFormat.prototype.resolvedOptions;
            Intl.DateTimeFormat.prototype.resolvedOptions = function(){ var o = _resolved.call(this); o.timeZone = 'UTC'; return o; };
        } catch(e){}
        // Uniform language fingerprint.
        try {
            Object.defineProperty(navigator, 'language', { get: function(){ return 'en-US'; } });
            Object.defineProperty(navigator, 'languages', { get: function(){ return ['en-US', 'en']; } });
        } catch(e){}
    })();
    """

    // MARK: - Layout Fixer Source (injected early for all tabs)

    /// The source for the layout & viewport quality fixer user script.
    /// Kept as a static string here (single file, easy to evolve) and injected from makeWebView
    /// at .atDocumentStart so it wins the race against page-authored viewport tags and early layout JS.
    ///
    /// Defensive by design: try/catch everywhere, double-install guard, no style mutations that would
    /// fight legitimate full-bleed or canvas designs.
    /// Enhanced with !important, repeated stabs, and reflow nudges to help sites whose main UI
    /// (e.g. speedtest "GO" button) does JS-based measurement + centering on first paint.
    static let layoutFixerSource: String = """
    (function() {
        'use strict';
        if (window.__searxlyLayoutFixerInstalled) { return; }
        window.__searxlyLayoutFixerInstalled = true;

        // Skip entirely for YouTube — our pane sizing fixes can interfere with the YouTube player's
        // own responsive video container, control bar positioning, and fullscreen handling.
        // YouTube manages its own viewport and layout very carefully.
        const h = location.hostname || '';
        if (h.includes('youtube.com') || h.includes('youtu.be')) { return; }

        // 1. Guarantee a sane viewport meta tag (override whatever the server sent).
        // This is critical so the page sizes its containers to the actual pane width we give it
        // (the area to the right of the sidebar) instead of a full desktop window or a bad early size.
        try {
            let vp = document.querySelector('meta[name="viewport"]');
            if (!vp) {
                vp = document.createElement('meta');
                vp.name = 'viewport';
                (document.head || document.documentElement).appendChild(vp);
            }
            vp.setAttribute('content',
                'width=device-width, initial-scale=1.0, minimum-scale=0.2, maximum-scale=5.0, ' +
                'user-scalable=yes, shrink-to-fit=no, viewport-fit=cover'
            );
        } catch (e) {}

        // 2. Early defensive containment + box model with !important.
        // Also force body/html to full width + auto margins early. This helps 'margin: 0 auto'
        // centered heroes (the GO button + server selector on speedtest etc.) actually center
        // inside the real pane width instead of latching to the left with huge empty space on the right.
        try {
            const style = document.createElement('style');
            style.textContent = 'html,body{max-width:100% !important;width:100% !important;box-sizing:border-box !important;margin-left:auto !important;margin-right:auto !important;}';
            (document.head || document.documentElement).appendChild(style);
        } catch (e) {}

        // 3. Schedule stabilization (resize + reflow) early + with extra delayed passes.
        // Combined with the native WebViewContainer (which now does setFrameSize + multi-pass
        // stabilize on attach / layout / didFinish), this gives JS-heavy pages (speedtest etc.)
        // several opportunities to see the correct final size and re-center their main content.
        function stabilizeOnce() {
            try {
                const w = window.innerWidth || 0;
                const docEl = document.documentElement;
                const body = document.body;

                // Force full width + auto margins (same reason as the early <style>).
                // Doing it again at DOMContentLoaded / load time overrides anything the page
                // set on the root during its own initialization.
                docEl.style.setProperty('width', '100%', 'important');
                if (body) {
                    body.style.setProperty('width', '100%', 'important');
                    body.style.setProperty('margin-left', 'auto', 'important');
                    body.style.setProperty('margin-right', 'auto', 'important');
                }

                window.dispatchEvent(new Event('resize'));
                void docEl.offsetWidth;
                if (body) void body.offsetWidth;

                // Width perturbation trick: temporarily bump the width by a sub-pixel then restore.
                // Extremely effective at forcing re-measure for sites that cached a bad layout rect
                // (e.g. hero button placed at left:0 or not centered) on the very first paint.
                if (w > 0) {
                    const old = docEl.style.width;
                    docEl.style.width = (w + 0.5) + 'px';
                    void docEl.offsetWidth;
                    if (body) void body.offsetWidth;
                    docEl.style.width = old || '';
                    void docEl.offsetWidth;
                }

                window.dispatchEvent(new Event('resize'));
            } catch (e) {}
        }

        function scheduleStabs() {
            setTimeout(stabilizeOnce, 16);
            setTimeout(stabilizeOnce, 80);
            setTimeout(stabilizeOnce, 180);
        }

        if (document.readyState === 'complete' || document.readyState === 'interactive') {
            scheduleStabs();
        } else {
            document.addEventListener('DOMContentLoaded', scheduleStabs, { once: true });
        }
        window.addEventListener('load', scheduleStabs, { once: true });
    })();
    """

    /// Convenience helper for future "Clear all private data" features.
    /// Note: Truly ephemeral tabs are automatically cleaned when their WKWebView is released.
    /// This method can be expanded later to also wipe any shared caches if needed.
    @MainActor
    static func clearEphemeralData() {
        precondition(Thread.isMainThread, "WebViewFactory.clearEphemeralData must be called on the main thread")
        // Currently a no-op placeholder. Real private tabs are isolated by design.
        // In the future we can iterate over active private webviews and force-clear here if desired.
        Log.web.info("WebViewFactory: clearEphemeralData() called (ephemeral tabs are self-cleaning)")
    }
}
