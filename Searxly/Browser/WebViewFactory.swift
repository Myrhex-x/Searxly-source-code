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

    /// Safari User-Agent token appended to WebKit's default UA so every tab reports as desktop Safari
    /// on macOS, blending Searxly users into the large Safari population instead of exposing a unique
    /// "Searxly/1.0" tag. WebKit fills the platform prefix (correct AppleWebKit build for the OS); only
    /// this pinned marketing version can go stale, so refresh it periodically. Mirrors the UA already
    /// used for YouTube compatibility in WebViewRepresentable.
    static let safariUserAgentToken = "Version/17.4 Safari/605.1.15"

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

        // User-Agent: present every tab as desktop Safari on macOS. WKWebView's default UA omits the
        // "Version/x Safari/x" token (which marks the client as an embedded-WebKit app), and we used to
        // append a unique "Searxly/1.0" / "Searxly/1.0 (Private)" tag — both are fingerprinting signals
        // that single Searxly users out (the "(Private)" tag also literally advertised private mode).
        // Appending the Safari token makes WebKit emit the standard Safari UA, so browsing blends into
        // the large Safari-on-macOS population. (Same effective UA already trusted for YouTube.)
        configuration.applicationNameForUserAgent = Self.safariUserAgentToken

        // HTTPS upgrade: silently promote http:// → https:// for hosts known to support it, instead of
        // loading the page insecurely first. A privacy-first default; no effect on http-only sites
        // (they fall back to http rather than failing). Available since macOS 11.3.
        configuration.upgradeKnownHostsToHTTPS = true

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

        // Disable getUserMedia (camera/mic) everywhere — reduces a fingerprint vector and a permission
        // surface. NOTE: this does NOT stop the WebRTC IP leak (RTCPeerConnection can still gather ICE
        // candidates without media); that's neutralized in Maximum Privacy by strictPrivacySource.
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

        // Lane B userscripts (in-house, AI-authorable extensions). Injected into an isolated content
        // world, scoped to the user's match patterns, and ONLY on standard tabs — never Private/Onion.
        // No-op when the feature is off or there are no enabled+valid scripts. See Extensions/.
        UserScriptManager.shared.apply(to: configuration, mode: mode)

        // Lane A (real WebExtensions). Attach the shared WKWebExtensionController so installed extensions
        // can run on standard tabs. Flag-gated (default OFF) + macOS 15.4+, so the controller isn't even
        // created for normal users. The manager re-checks flag + standard-only. See Extensions/LaneA/.
        if #available(macOS 15.4, *), ExtensionFeatures.laneAEnabled {
            ExtensionManager.shared.configure(configuration, mode: mode)
        }

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

        // Link-hover reporter: posts the destination of the link under the cursor to native so the
        // status strip (bottom-left) can show where a link goes before you click it — a Safari staple
        // and an anti-phishing signal. Deduped to fire only when the hovered link changes.
        let linkHoverScript = WKUserScript(
            source: Self.linkHoverReporterSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(linkHoverScript)

        // Fingerprint surface reduction (every tab, all frames): clamp navigator.hardwareConcurrency to a
        // common Apple-Silicon value so high-core Macs don't stand out. See fingerprintMitigationSource.
        let fingerprintScript = WKUserScript(
            source: Self.fingerprintMitigationSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(fingerprintScript)

        // Strict fingerprint cluster — Maximum Privacy ONLY (opt-in; may break some sites). Farbles
        // canvas/audio/WebGL readbacks, reports the content window as the screen (the CYT screen rows),
        // trims the referrer, and clears window.name across sites. Gated on the persistent app mode so
        // Normal/Encrypted users never see it. See strictPrivacySource.
        if PrivacyManager.shared.appPrivacyMode == .maximum {
            let strictScript = WKUserScript(
                source: Self.strictPrivacySource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            configuration.userContentController.addUserScript(strictScript)
        }

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

        // Maximum Privacy + Tor: route this tab through Tor's local SOCKS proxy (the same mechanism
        // onion tabs use) so browsing genuinely traverses Tor and the real IP is hidden. Maximum + VPN
        // needs nothing here — that tunnel is whole-device and every tab rides it automatically.
        let maxTorRouting = (PrivacyManager.shared.appPrivacyMode == .maximum
                             && PrivacyManager.shared.maxProtection == .tor)

        switch mode {
        case .standard:
            // Default behavior: persistent website data store (cookies, localStorage, cache survive).
            // UA is set once in the shared configuration above (desktop-Safari for every mode).
            if maxTorRouting { Self.applyTorRouting(to: configuration) }
            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            // Lane A: register this standard tab with the WebExtension controller. Attaching the controller
            // (above) is not enough — the engine only injects content scripts into tabs it has been told
            // about via didOpenTab. Flag-gated + 15.4, so it's a no-op unless an extension is installed.
            if #available(macOS 15.4, *), ExtensionFeatures.laneAEnabled {
                ExtensionManager.shared.registerTab(webView, active: true)
            }
            return webView

        case .privateEphemeral:
            // Fresh non-persistent data store for this tab only.
            // Data is never written to disk and is released when the webview is destroyed.
            let ephemeralDataStore = WKWebsiteDataStore.nonPersistent()
            configuration.websiteDataStore = ephemeralDataStore

            // (Process pool separation is no longer effective per Apple; the non-persistent
            // WKWebsiteDataStore below is what actually keeps Private tab data isolated and in-memory only.)

            // Maximum Privacy + Tor: also route private tabs through Tor (overrides the store above).
            if maxTorRouting { Self.applyTorRouting(to: configuration) }

            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            return webView

            // FUTURE (per-site exceptions): When we have a host allow-list,
            // we can decide here (or in the navigation delegate) to swap in
            // the default persistent store for specific hosts even inside a
            // nominally "Private" tab.

        case .onion:
            // Onion tab: non-persistent store, traffic routed through Tor's local SOCKS5. SOCKS5h
            // resolves the hostname (incl. .onion) at the proxy, so onions work with no DNS leak.
            // Tor must be bootstrapped first — openOnionURL awaits ensureReadyAndRunning() before loading.
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

            // UA is the same desktop-Safari string as every other tab (set in the shared configuration
            // above), so onion tabs don't stand out from the user's other tabs.
            let webView = SearxlyWebView(frame: .zero, configuration: configuration)
            return webView
        }
    }

    /// Injected into every tab at document start (all frames). Clamps navigator.hardwareConcurrency to a
    /// common Apple-Silicon value (≤ 8) so Pro/Max/Ultra Macs collapse into the modal 8-core population
    /// instead of standing out. We only ever report FEWER cores than the machine has, never more, so a
    /// worker pool just sizes down — no breakage. Defined on Navigator.prototype with a native-shaped
    /// descriptor to limit the "this getter was replaced" tell.
    ///
    /// Scope: page + subframes — the path commodity fingerprinters use. Worker-context coverage (which
    /// means wrapping the Worker constructor, with its own breakage surface) is deferred to a future
    /// Strict-mode farbling layer. navigator.deviceMemory is Chrome-only and already absent in WebKit.
    static let fingerprintMitigationSource: String = """
    (function() {
        'use strict';
        try {
            var cores = Math.min((navigator.hardwareConcurrency | 0) || 8, 8);
            Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', {
                get: function () { return cores; },
                enumerable: true,
                configurable: true
            });
        } catch (e) {}
    })();
    """

    /// Injected into every tab at document start (all frames) ONLY in Maximum Privacy. The Strict
    /// fingerprint cluster: per-read farbling of canvas / WebGL / audio readbacks, reporting the content
    /// window as the screen (so the screen-dimension fingerprint rows match the window, Tor-letterbox
    /// style), trimming the referrer to same-origin, and clearing window.name across sites. Every block
    /// is independently try/caught with a double-install guard. This is the breakage-prone, opt-in layer
    /// — NOT injected in Normal/Encrypted.
    ///
    /// Honest limits (WKWebView ceiling): the shim is detectable, Worker-context reads aren't covered,
    /// and TLS/JA3 + font fingerprints are untouched — this raises the cost of fingerprinting, it does
    /// not make the browser un-fingerprintable. matchMedia interception is scoped to device-width/height
    /// only (the FP vectors), so ordinary responsive (max-width/min-width) layouts are left alone.
    static let strictPrivacySource: String = """
    (function() {
        'use strict';
        if (window.__searxlyStrictInstalled) { return; }
        window.__searxlyStrictInstalled = true;

        function jitter() { return (Math.random() < 0.5) ? -1 : 1; }
        function clampByte(v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
        function defGet(obj, prop, fn) {
            try { Object.defineProperty(obj, prop, { get: fn, configurable: true }); } catch (e) {}
        }

        // --- WebRTC: neutralize RTCPeerConnection so a page can't discover the real IP ---
        // This is the single most important block in Maximum Privacy: RTCPeerConnection gathers ICE
        // candidates (host = your LAN IP, srflx = your PUBLIC IP via a STUN server) over UDP, which the
        // WebView's SOCKS5 proxy in Tor mode DOES NOT carry (SOCKS5 is TCP) — so WebRTC would leak the
        // very IP this mode hides, straight past Tor. `mediaDevicesEnabled=false` only stops camera/mic,
        // not this. We make the constructors read as absent (typeof … === 'undefined'), the same as a
        // browser built without WebRTC. Expected trade-off: WebRTC apps (video calls) won't work in
        // Maximum Privacy — acceptable for a mode that already may break sites.
        try {
            ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection',
             'RTCDataChannel', 'RTCSessionDescription', 'RTCIceCandidate'].forEach(function (name) {
                try {
                    Object.defineProperty(window, name, { get: function () { return undefined; }, configurable: false });
                } catch (e) {
                    try { window[name] = undefined; } catch (e2) {}
                }
            });
            // Legacy getUserMedia entry point (belt-and-suspenders with mediaDevicesEnabled=false).
            try { navigator.getUserMedia = undefined; } catch (e) {}
        } catch (e) {}

        // --- Canvas 2D farbling: perturb a sparse subset of pixels on every readback ---
        try {
            var origGID = CanvasRenderingContext2D.prototype.getImageData;
            CanvasRenderingContext2D.prototype.getImageData = function() {
                var img = origGID.apply(this, arguments);
                try {
                    var d = img.data;
                    for (var i = 0; i < d.length; i += 256) {
                        d[i]   = clampByte(d[i]   + jitter());
                        d[i+1] = clampByte(d[i+1] + jitter());
                        d[i+2] = clampByte(d[i+2] + jitter());
                    }
                } catch (e) {}
                return img;
            };
            function nudge(canvas) {
                try {
                    var ctx = canvas.getContext('2d');
                    if (!ctx || !canvas.width || !canvas.height) { return; }
                    var px = origGID.call(ctx, 0, 0, 1, 1);
                    px.data[0] = clampByte(px.data[0] + jitter());
                    ctx.putImageData(px, 0, 0);
                } catch (e) {}
            }
            var origTDU = HTMLCanvasElement.prototype.toDataURL;
            HTMLCanvasElement.prototype.toDataURL = function() { nudge(this); return origTDU.apply(this, arguments); };
            if (HTMLCanvasElement.prototype.toBlob) {
                var origTB = HTMLCanvasElement.prototype.toBlob;
                HTMLCanvasElement.prototype.toBlob = function() { nudge(this); return origTB.apply(this, arguments); };
            }
        } catch (e) {}

        // --- WebGL: standardize the high-signal strings + perturb readback ---
        try {
            function patchGL(proto) {
                if (!proto) { return; }
                var origGP = proto.getParameter;
                proto.getParameter = function(p) {
                    if (p === 37445) { return 'Apple Inc.'; }   // UNMASKED_VENDOR_WEBGL
                    if (p === 37446) { return 'Apple GPU'; }    // UNMASKED_RENDERER_WEBGL
                    return origGP.apply(this, arguments);
                };
                var origRP = proto.readPixels;
                proto.readPixels = function() {
                    origRP.apply(this, arguments);
                    try {
                        var buf = arguments[6];
                        if (buf && buf.length) { for (var i = 0; i < buf.length; i += 503) { buf[i] = buf[i] ^ 1; } }
                    } catch (e) {}
                };
            }
            if (window.WebGLRenderingContext) { patchGL(WebGLRenderingContext.prototype); }
            if (window.WebGL2RenderingContext) { patchGL(WebGL2RenderingContext.prototype); }
        } catch (e) {}

        // --- Audio: add sub-audible noise to analyser / buffer readbacks ---
        try {
            if (window.AnalyserNode) {
                var origFFD = AnalyserNode.prototype.getFloatFrequencyData;
                AnalyserNode.prototype.getFloatFrequencyData = function(arr) {
                    origFFD.apply(this, arguments);
                    try { for (var i = 0; i < arr.length; i += 64) { arr[i] += (Math.random() - 0.5) * 1e-3; } } catch (e) {}
                };
            }
            if (window.AudioBuffer) {
                var origGCD = AudioBuffer.prototype.getChannelData;
                AudioBuffer.prototype.getChannelData = function() {
                    var d = origGCD.apply(this, arguments);
                    try { for (var i = 0; i < d.length; i += 1000) { d[i] += (Math.random() - 0.5) * 1e-7; } } catch (e) {}
                    return d;
                };
            }
        } catch (e) {}

        // --- Screen metrics: report the content window, not the physical display ---
        try {
            defGet(Screen.prototype, 'width',       function() { return window.innerWidth; });
            defGet(Screen.prototype, 'height',      function() { return window.innerHeight; });
            defGet(Screen.prototype, 'availWidth',  function() { return window.innerWidth; });
            defGet(Screen.prototype, 'availHeight', function() { return window.innerHeight; });
            defGet(window, 'screenX',     function() { return 0; });
            defGet(window, 'screenY',     function() { return 0; });
            defGet(window, 'screenLeft',  function() { return 0; });
            defGet(window, 'screenTop',   function() { return 0; });
            defGet(window, 'outerWidth',  function() { return window.innerWidth; });
            defGet(window, 'outerHeight', function() { return window.innerHeight; });
        } catch (e) {}

        // --- matchMedia: only intercept device-width/height (the FP vectors); pass everything else through ---
        try {
            var origMM = window.matchMedia;
            window.matchMedia = function(q) {
                try {
                    var m = /device-(width|height)\\s*:\\s*(\\d+)px/.exec(String(q));
                    if (m) {
                        var actual = (m[1] === 'width') ? window.innerWidth : window.innerHeight;
                        var matches = (parseInt(m[2], 10) === actual);
                        return { matches: matches, media: String(q), onchange: null,
                                 addListener: function(){}, removeListener: function(){},
                                 addEventListener: function(){}, removeEventListener: function(){},
                                 dispatchEvent: function(){ return false; } };
                    }
                } catch (e) {}
                return origMM.apply(this, arguments);
            };
        } catch (e) {}

        // --- window.name: don't let it ferry an identifier across sites ---
        try {
            if (document.referrer) {
                var refHost = '';
                try { refHost = new URL(document.referrer).hostname; } catch (e) {}
                if (refHost && refHost !== location.hostname) { window.name = ''; }
            }
        } catch (e) {}

        // --- referrer: keep referrers only on-site (cross-site navigations send none) ---
        try {
            var meta = document.createElement('meta');
            meta.name = 'referrer';
            meta.content = 'same-origin';
            (document.head || document.documentElement).appendChild(meta);
        } catch (e) {}
    })();
    """

    /// Local SOCKS5 endpoint for the bundled Tor client. Shared by onion tabs and Maximum-Privacy+Tor
    /// routing so both reach Tor the same way (SOCKS5h — hostnames resolved at the proxy, no DNS leak).
    static func torSocksEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: NWEndpoint.Host(TorRuntimeConfig.socksHost),
            port: NWEndpoint.Port(rawValue: TorRuntimeConfig.socksPort) ?? 19050
        )
    }

    /// Routes a tab through Tor's local SOCKS proxy and applies the onion IP-leak hardening (WebRTC /
    /// media-device / geolocation neutering). Used for Maximum Privacy + Tor so standard and private
    /// tabs traverse Tor exactly like onion tabs, hiding the real IP. Forces a non-persistent store.
    @MainActor
    static func applyTorRouting(to configuration: WKWebViewConfiguration) {
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: torSocksEndpoint())]
        configuration.websiteDataStore = store
        configuration.userContentController.addUserScript(
            WKUserScript(source: onionHardeningSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
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

    // MARK: - Link Hover Reporter Source

    /// Injected at document start. Reports the href of the link under the cursor (or "" when none) to
    /// the `linkHover` message handler, deduped so it only fires when the hovered link changes. Wrapped
    /// in try/catch and a double-install guard; purely passive (no DOM mutation).
    static let linkHoverReporterSource: String = """
    (function() {
        'use strict';
        if (window.__searxlyLinkHoverInstalled) { return; }
        window.__searxlyLinkHoverInstalled = true;

        var last = null;

        function nearestHref(el) {
            try {
                while (el && el.nodeType === 1 && el !== document.documentElement) {
                    if (el.tagName === 'A' && el.href) { return el.href; }
                    el = el.parentElement;
                }
            } catch (e) {}
            return null;
        }

        function report(url) {
            var value = url || '';
            if (value === last) { return; }
            last = value;
            try { window.webkit.messageHandlers.linkHover.postMessage(value); } catch (e) {}
        }

        document.addEventListener('mouseover', function(e) {
            report(nearestHref(e.target));
        }, true);

        document.addEventListener('mouseout', function(e) {
            // Only clear when we've actually left a link (and aren't entering another).
            if (!nearestHref(e.relatedTarget)) { report(null); }
        }, true);

        window.addEventListener('blur', function() { report(null); });
        document.addEventListener('mouseleave', function() { report(null); }, true);
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

        // Only a handful of JS-measured, centered single-page UIs (speedtest gauges etc.) need the heavy
        // width-forcing + sub-pixel reflow perturbation. For everything else the viewport meta below is
        // enough, and forcing width:100% !important would needlessly fight the site's own layout.
        // Keep this in sync with WebViewContainer.aggressiveLayoutHostFragments.
        const AGGRESSIVE = ['speedtest.net', 'speedtest.com'];
        const needsAggressive = AGGRESSIVE.some(function(f){ return h.indexOf(f) !== -1; });

        // 1. Guarantee a sane viewport meta tag (override whatever the server sent). Cheap, one-time, and
        // the primary fix for "super wide" pages: it makes the page size its containers to the actual
        // pane width we give it (the area right of the sidebar) instead of a full desktop window.
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

        // 2. Gentle, universal overflow guard: prevent horizontal blowout without overriding the site's
        // own width/centering. (The aggressive width:100% + margin-auto forcing is added only below for
        // the quirk hosts that actually need it.)
        try {
            const style = document.createElement('style');
            style.textContent = 'html,body{max-width:100% !important;box-sizing:border-box !important;}';
            (document.head || document.documentElement).appendChild(style);
        } catch (e) {}

        // 3. Non-quirk path: a single resize ping at DOMContentLoaded + load is all most pages need to
        // settle responsive layout against the real pane width. No forced reflow, no perturbation.
        if (!needsAggressive) {
            function pingResize() { try { window.dispatchEvent(new Event('resize')); } catch (e) {} }
            if (document.readyState === 'complete' || document.readyState === 'interactive') {
                pingResize();
            } else {
                document.addEventListener('DOMContentLoaded', pingResize, { once: true });
            }
            window.addEventListener('load', pingResize, { once: true });
            return;
        }

        // 4. Quirk path (speedtest-class): force full width + auto margins and schedule delayed reflow
        // passes so JS-measured, centered heroes re-measure against the real pane width.
        try {
            const style = document.createElement('style');
            style.textContent = 'html,body{width:100% !important;margin-left:auto !important;margin-right:auto !important;}';
            (document.head || document.documentElement).appendChild(style);
        } catch (e) {}

        function stabilizeOnce() {
            try {
                const w = window.innerWidth || 0;
                const docEl = document.documentElement;
                const body = document.body;

                docEl.style.setProperty('width', '100%', 'important');
                if (body) {
                    body.style.setProperty('width', '100%', 'important');
                    body.style.setProperty('margin-left', 'auto', 'important');
                    body.style.setProperty('margin-right', 'auto', 'important');
                }

                window.dispatchEvent(new Event('resize'));
                void docEl.offsetWidth;
                if (body) void body.offsetWidth;

                // Width perturbation: temporarily bump the width by a sub-pixel then restore. Forces a
                // re-measure for sites that cached a bad layout rect on the very first paint.
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
