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

        // Searxly Maximum, Safer/Safest: turn on WebKit's Lockdown Mode via SPI — real, engine-level
        // JIT-off (the #1 exploit mitigation, the exact thing JS can't do), plus WASM/other surface cuts.
        // Guarded + best-effort: if the symbol is gone on a future WebKit this no-ops, and JS-off (Safest,
        // via the nav delegate) + the JS farbling remain the floor. At Safest JS is off entirely anyway;
        // at Safer this keeps JS working while killing the JIT.
        if Edition.isMaximum, MaximumSecurity.effective.dropsHighRiskAPIs {
            for name in ["_setLockdownModeEnabled:", "_setCaptivePortalModeEnabled:"] {
                let sel = NSSelectorFromString(name)
                if webpagePrefs.responds(to: sel) {
                    webpagePrefs.perform(sel, with: NSNumber(value: true))  // non-nil arg → BOOL true
                    break
                }
            }
        }

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

        // Tier-1 engine-level feature hardening (Searxly Maximum): turn privacy-relevant WebKit features
        // OFF in the ENGINE itself — real and undetectable, unlike the JS shims that stay as the floor.
        Self.applyEngineHardening(to: configuration.preferences, level: MaximumSecurity.effective)

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
            if maxTorRouting {
                Self.applyTorRouting(to: configuration)   // forces a non-persistent store already
            } else if AmnesiaMode.isActive || Edition.isMaximum {
                // Amnesic sessions — and ALL of Searxly Maximum, including its VPN lane — keep even
                // standard tabs RAM-only: cookies / cache / localStorage are never written to disk, can't
                // be used to correlate you across sites, and vanish on quit. (Maximum + Tor already gets a
                // non-persistent store via applyTorRouting; this covers Maximum + VPN too.)
                configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            }
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
            onionStore.proxyConfigurations = [Self.makeTorProxyConfiguration()]
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

    /// Tier-1 engine-level hardening (Searxly Maximum): flip privacy-relevant WebKit features OFF in the
    /// ENGINE via private SPI (`_experimentalFeatures` / `_internalDebugFeatures` + the matching
    /// `_setEnabled:for…Feature:` setters). Engine-off is undetectable and unbypassable, unlike the JS
    /// shims — which stay as the floor. Every call is guarded by `responds(to:)`, and the DISABLE uses the
    /// nil-argument trick (a nil `id` argument reads as `BOOL false`), so on any future WebKit where a
    /// symbol is gone this simply no-ops. It can't crash and can't make things worse.
    static func applyEngineHardening(to preferences: WKPreferences, level: MaximumSecurityLevel) {
        guard Edition.isMaximum else { return }

        // Off at every Maximum level: IP-adjacent + high-entropy features already neutered from JS.
        let alwaysOff = ["peerconnection", "webrtc", "mediastream", "mediadevices", "mediarecorder",
                         "gamepad", "webnfc", "webserial", "webhid", "webusb", "webbluetooth",
                         "battery", "networkinformation", "prefetch", "prerender", "speculationrules"]
        // Also off at Safer / Safest: the heavy GPU + WASM exploit/entropy surface.
        let saferOff = ["webgl", "webgpu", "webassembly", "offscreencanvas"]
        let tokens = level.dropsHighRiskAPIs ? (alwaysOff + saferOff) : alwaysOff

        func matches(_ s: String) -> Bool {
            let l = s.lowercased()
            return tokens.contains { l.contains($0) }
        }

        func disable(list listSelector: String, setter setterSelector: String) {
            let classObject = WKPreferences.self as AnyObject
            let listSel = NSSelectorFromString(listSelector)
            guard classObject.responds(to: listSel),
                  let features = classObject.perform(listSel)?.takeUnretainedValue() as? [NSObject] else { return }
            let setSel = NSSelectorFromString(setterSelector)
            guard preferences.responds(to: setSel) else { return }
            let keySel = NSSelectorFromString("key")
            let nameSel = NSSelectorFromString("name")
            for feature in features {
                let key = feature.responds(to: keySel) ? (feature.value(forKey: "key") as? String ?? "") : ""
                let name = feature.responds(to: nameSel) ? (feature.value(forKey: "name") as? String ?? "") : ""
                if matches(key) || matches(name) {
                    // nil first arg → the BOOL parameter reads as 0 (false) → the feature is disabled.
                    preferences.perform(setSel, with: nil, with: feature)
                }
            }
        }

        disable(list: "_experimentalFeatures", setter: "_setEnabled:forExperimentalFeature:")
        disable(list: "_internalDebugFeatures", setter: "_setEnabled:forInternalDebugFeature:")
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
    /// fingerprint cluster — each block independently try/caught behind a double-install guard:
    ///   • WebRTC neutered (no RTCPeerConnection → no IP leak around the Tor SOCKS proxy)
    ///   • canvas / WebGL / audio / OffscreenCanvas readbacks farbled per-read
    ///   • font metrics noised (canvas measureText) + FontFaceSet enumeration capped to common/registered
    ///   • WebGL vendor+renderer standardized to Apple; WebGPU (navigator.gpu) made absent
    ///   • screen == content window; window/screen/documentElement/visualViewport letterboxed to a bucket
    ///   • devicePixelRatio→1×/2×; colour depth→24 (low-entropy display)
    ///   • timezone reported as UTC (getTimezoneOffset + Intl) so the local region can't be read
    ///   • referrer trimmed to same-origin; window.name cleared across sites
    ///   • every shim native-code-masked so Function.prototype.toString can't reveal the tampering
    /// This is the breakage-prone, opt-in layer — NOT injected in Normal/Encrypted.
    ///
    /// Honest limits (WKWebView ceiling): shims are native-masked but still detectable via descriptor
    /// inspection or a fresh-realm (dynamically-created about:blank iframe) escape. Font metrics are now
    /// noised (canvas measureText) and FontFaceSet enumeration capped, but the DOM offsetWidth font-probe
    /// and Worker-context reads stay open; letterboxing now spans innerWidth/screen/documentElement/
    /// visualViewport, yet a full-width element's getBoundingClientRect still reveals the true width (true
    /// letterboxing needs native content margins); TLS/JA3 is untouched. This raises the cost of
    /// fingerprinting; it does not make the browser un-fingerprintable — only a patched engine would.
    /// matchMedia interception is scoped to device-width/height (the FP vectors), so ordinary responsive
    /// (max-width/min-width) layouts are left alone.
    static var strictPrivacySource: String { """
    (function() {
        'use strict';
        if (window.__searxlyStrictInstalled) { return; }
        window.__searxlyStrictInstalled = true;

        function jitter() { return (Math.random() < 0.5) ? -1 : 1; }
        function clampByte(v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

        // --- Native-code masking -------------------------------------------------------------------
        // Report every shim below as `[native code]` and hide the masking itself, so a fingerprinter
        // reading Function.prototype.toString on our overrides can't spot the tampering (the "this is a
        // privacy browser" tell that plain JS farbling otherwise leaks). Honest limit: this raises the
        // cost of detection, it does not remove it — descriptor inspection or a fresh-realm escape can
        // still find shims. That's the WKWebView JS ceiling; only a patched engine closes it fully.
        var mask = (function () {
            var nativeToString = Function.prototype.toString;
            var shimNames = new WeakMap();
            function toString() {
                try { if (shimNames.has(this)) { return 'function ' + shimNames.get(this) + '() { [native code] }'; } } catch (e) {}
                return nativeToString.call(this);
            }
            shimNames.set(toString, 'toString');
            try {
                Object.defineProperty(Function.prototype, 'toString', {
                    value: toString, writable: true, enumerable: false, configurable: true
                });
            } catch (e) {}
            return function (fn, name) {
                try { shimNames.set(fn, name || (fn && fn.name) || ''); } catch (e) {}
                return fn;
            };
        })();

        // Mask the always-on hardwareConcurrency getter installed earlier (fingerprintMitigationSource).
        try {
            var hcDesc = Object.getOwnPropertyDescriptor(Navigator.prototype, 'hardwareConcurrency');
            if (hcDesc && hcDesc.get) { mask(hcDesc.get, 'get hardwareConcurrency'); }
        } catch (e) {}

        // Getter installer that native-code-masks the getter it defines.
        function defGet(obj, prop, fn) {
            try { Object.defineProperty(obj, prop, { get: mask(fn, 'get ' + prop), configurable: true }); } catch (e) {}
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

        // --- Fonts (metrics + enumeration) — Maximum edition only (see strictFontDefenseJS). ---
        \(Edition.isMaximum ? Self.strictFontDefenseJS : "")

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

        // --- Screen metrics + viewport letterboxing --------------------------------------------------
        // Report the content window (not the physical display), AND round it to a coarse bucket so an
        // exact pixel size can't single you out — the entropy in window.innerWidth/Height is otherwise
        // one of the strongest passive signals. This is "letterbox the reported metrics": CSS layout /
        // media queries still use the real viewport (so nothing breaks), but scripts reading the size
        // see a low-entropy bucket. Honest limit: a script can still compare against
        // documentElement.clientWidth to detect the rounding — closing that needs real content margins
        // (a patched engine / Tor Browser-style letterboxing), which WKWebView can't do here.
        try {
            var __lbStepW = 100, __lbStepH = 100;
            function __lb(v, s) { v = v | 0; return v <= 0 ? s : Math.max(s, Math.round(v / s) * s); }
            function __origGetter(obj, prop) {
                var o = obj;
                while (o) { var d = Object.getOwnPropertyDescriptor(o, prop); if (d && d.get) { return d.get; } o = Object.getPrototypeOf(o); }
                return null;
            }
            var __iwGet = __origGetter(window, 'innerWidth');
            var __ihGet = __origGetter(window, 'innerHeight');
            if (__iwGet) { defGet(window, 'innerWidth',  function() { return __lb(__iwGet.call(window), __lbStepW); }); }
            if (__ihGet) { defGet(window, 'innerHeight', function() { return __lb(__ihGet.call(window), __lbStepH); }); }

            // screen == the (now bucketed) content window, and its position is pinned to the origin.
            defGet(Screen.prototype, 'width',       function() { return window.innerWidth; });
            defGet(Screen.prototype, 'height',      function() { return window.innerHeight; });
            defGet(Screen.prototype, 'availWidth',  function() { return window.innerWidth; });
            defGet(Screen.prototype, 'availHeight', function() { return window.innerHeight; });
            defGet(Screen.prototype, 'availLeft',   function() { return 0; });
            defGet(Screen.prototype, 'availTop',    function() { return 0; });
            defGet(window, 'screenX',     function() { return 0; });
            defGet(window, 'screenY',     function() { return 0; });
            defGet(window, 'screenLeft',  function() { return 0; });
            defGet(window, 'screenTop',   function() { return 0; });
            defGet(window, 'outerWidth',  function() { return window.innerWidth; });
            defGet(window, 'outerHeight', function() { return window.innerHeight; });
            // Letterboxing (cont.) — Maximum edition only; injected here (inside this block) so it can see
            // __origGetter, which is block-scoped to this try under 'use strict'. See strictLetterboxExtrasJS.
            \(Edition.isMaximum ? Self.strictLetterboxExtrasJS : "")
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

        // --- OffscreenCanvas 2D farbling (main thread): close the non-Worker OffscreenCanvas readback
        //     bypass of the canvas block above. Worker-scope OffscreenCanvas still isn't covered — that
        //     needs wrapping the Worker constructor, which is breakage-prone and deferred. ---
        try {
            if (window.OffscreenCanvasRenderingContext2D) {
                var oGID = OffscreenCanvasRenderingContext2D.prototype.getImageData;
                OffscreenCanvasRenderingContext2D.prototype.getImageData = mask(function() {
                    var img = oGID.apply(this, arguments);
                    try { var d = img.data; for (var i = 0; i < d.length; i += 256) { d[i] = clampByte(d[i] + jitter()); } } catch (e) {}
                    return img;
                }, 'getImageData');
            }
        } catch (e) {}

        // --- devicePixelRatio + colour depth: collapse scaled / HiDPI displays into the 1x / 2x, 24-bit
        //     Mac population so an unusual scale factor (1.25, 1.5, 3, …) can't single you out. ---
        try {
            var _dpr = window.devicePixelRatio || 1;
            var _normDpr = _dpr >= 1.5 ? 2 : 1;
            Object.defineProperty(window, 'devicePixelRatio', { get: mask(function () { return _normDpr; }, 'get devicePixelRatio'), configurable: true });
        } catch (e) {}
        defGet(Screen.prototype, 'colorDepth', function () { return 24; });
        defGet(Screen.prototype, 'pixelDepth', function () { return 24; });

        // --- Timezone: report UTC so the local region can't be read from JS (offset + Intl only; Date's
        //     local display methods are left intact to avoid breaking legitimate time UIs). This mirrors
        //     the per-onion-tab hardening, extended to EVERY Maximum tab (covers Maximum + VPN too). ---
        try {
            Date.prototype.getTimezoneOffset = mask(function () { return 0; }, 'getTimezoneOffset');
            if (window.Intl && Intl.DateTimeFormat) {
                var _resolved = Intl.DateTimeFormat.prototype.resolvedOptions;
                Intl.DateTimeFormat.prototype.resolvedOptions = mask(function () {
                    var o = _resolved.call(this);
                    try { o.timeZone = 'UTC'; } catch (e) {}
                    return o;
                }, 'resolvedOptions');
            }
        } catch (e) {}

        // --- WebGPU: the adapter / limits surface is high-entropy; make navigator.gpu read as absent
        //     (like older Safari). Trade-off: WebGPU pages fall back to WebGL / CPU in Maximum. ---
        try {
            if ('gpu' in navigator) {
                Object.defineProperty(navigator, 'gpu', { get: mask(function () { return undefined; }, 'get gpu'), configurable: true });
            }
        } catch (e) {}

        // --- Defense-in-depth: APIs Safari doesn't ship anyway (Battery, WebUSB / Serial / HID /
        //     Bluetooth, NetworkInformation). No-ops on today's WebKit; guarded so a future engine that
        //     adds one can't silently reopen a high-entropy or IP-adjacent vector. ---
        try {
            ['getBattery', 'usb', 'serial', 'hid', 'bluetooth', 'connection'].forEach(function (k) {
                try { if (k in navigator) { Object.defineProperty(navigator, k, { get: mask(function () { return undefined; }, 'get ' + k), configurable: true }); } } catch (e) {}
            });
        } catch (e) {}

        // --- Searxly Maximum hardening: speculative-networking off, uniform locale, and the security
        //     slider's GPU/WASM cuts. Edition-gated so the base app's Maximum-Privacy farbling is untouched.
        \(Edition.isMaximum ? Self.strictMaximumHardeningJS : "")

        // --- Native-code masking: register every function shim installed above so their toString reports
        //     `[native code]` (the getters were already masked inline via defGet / mask). ---
        try {
            mask(CanvasRenderingContext2D.prototype.getImageData, 'getImageData');
            mask(HTMLCanvasElement.prototype.toDataURL, 'toDataURL');
            if (HTMLCanvasElement.prototype.toBlob) { mask(HTMLCanvasElement.prototype.toBlob, 'toBlob'); }
            if (window.WebGLRenderingContext) { mask(WebGLRenderingContext.prototype.getParameter, 'getParameter'); mask(WebGLRenderingContext.prototype.readPixels, 'readPixels'); }
            if (window.WebGL2RenderingContext) { mask(WebGL2RenderingContext.prototype.getParameter, 'getParameter'); mask(WebGL2RenderingContext.prototype.readPixels, 'readPixels'); }
            if (window.AnalyserNode) { mask(AnalyserNode.prototype.getFloatFrequencyData, 'getFloatFrequencyData'); }
            if (window.AudioBuffer) { mask(AudioBuffer.prototype.getChannelData, 'getChannelData'); }
            mask(window.matchMedia, 'matchMedia');
        } catch (e) {}
    })();
    """
    }

    /// Font defense (measureText noise + FontFaceSet.check cap) injected into strictPrivacySource —
    /// Searxly Maximum edition ONLY, so the base app's own Maximum-Privacy farbling is never extended.
    /// Uses `mask` from the enclosing IIFE (function-scoped, so visible where this is interpolated).
    private static let strictFontDefenseJS: String = """
    try {
                var origMeasure = CanvasRenderingContext2D.prototype.measureText;
                CanvasRenderingContext2D.prototype.measureText = mask(function() {
                    var m = origMeasure.apply(this, arguments);
                    try {
                        var w = m.width + (Math.random() - 0.5) * 0.4;
                        Object.defineProperty(m, 'width', { get: mask(function() { return w; }, 'get width'), configurable: true });
                    } catch (e) {}
                    return m;
                }, 'measureText');
            } catch (e) {}

            try {
                if (document.fonts && typeof document.fonts.check === 'function') {
                    var __commonFonts = ['serif','sans-serif','monospace','cursive','fantasy','system-ui',
                        '-apple-system','blinkmacsystemfont','ui-serif','ui-sans-serif','ui-monospace','ui-rounded',
                        'helvetica','helvetica neue','arial','times','times new roman','courier','courier new',
                        'georgia','verdana','menlo','monaco','apple color emoji'];
                    var __origFontsCheck = document.fonts.check.bind(document.fonts);
                    function __familyAllowed(spec) {
                        var s = String(spec).toLowerCase();
                        for (var i = 0; i < __commonFonts.length; i++) { if (s.indexOf(__commonFonts[i]) >= 0) { return true; } }
                        try {
                            var it = document.fonts.values(), r;
                            while (!(r = it.next()).done) {
                                var fam = (r.value && r.value.family ? String(r.value.family) : '').toLowerCase().replace(/["']/g, '');
                                if (fam && s.indexOf(fam) >= 0) { return true; }
                            }
                        } catch (e) {}
                        return false;
                    }
                    document.fonts.check = mask(function(spec, text) {
                        try { return __familyAllowed(spec) ? __origFontsCheck(spec, text) : false; }
                        catch (e) { return false; }
                    }, 'check');
                }
            } catch (e) {}
    """

    /// Viewport letterbox extras (documentElement/body clientWidth + visualViewport) injected INSIDE
    /// strictPrivacySource's screen block — Searxly Maximum edition ONLY. Placed inside that block so it
    /// can see `__origGetter`, which is block-scoped there under 'use strict'.
    private static let strictLetterboxExtrasJS: String = """
    try {
                var __cwGet = __origGetter(Element.prototype, 'clientWidth');
                var __chGet = __origGetter(Element.prototype, 'clientHeight');
                function __isRootEl(el) { return el === document.documentElement || el === document.body; }
                if (__cwGet) {
                    Object.defineProperty(Element.prototype, 'clientWidth', { configurable: true,
                        get: mask(function() { return __isRootEl(this) ? window.innerWidth : __cwGet.call(this); }, 'get clientWidth') });
                }
                if (__chGet) {
                    Object.defineProperty(Element.prototype, 'clientHeight', { configurable: true,
                        get: mask(function() { return __isRootEl(this) ? window.innerHeight : __chGet.call(this); }, 'get clientHeight') });
                }
                if (window.visualViewport) {
                    defGet(window.visualViewport, 'width',  function() { return window.innerWidth; });
                    defGet(window.visualViewport, 'height', function() { return window.innerHeight; });
                }
            } catch (e) {}
    """

    /// Searxly Maximum ONLY — appended inside strictPrivacySource's IIFE (so it can use `mask`/`defGet`).
    /// Closes speculative-networking leaks (dns-prefetch / preconnect / prefetch / prerender open a
    /// connection or DNS lookup AHEAD of navigation, which can leak a hostname outside the Tor path),
    /// pins the reported locale to en-US, and — when the security slider is at Safer/Safest — drops the
    /// GPU + WebAssembly attack surface. Recomputed per webview so a slider change takes effect on rebuild.
    static var strictMaximumHardeningJS: String {
        let saferBlock = MaximumSecurity.effective.dropsHighRiskAPIs ? """
            // Safer/Safest: drop WebGL, WebGPU and WebAssembly — the highest exploit- and entropy-value web
            // APIs. Sites needing 3D/GPU/WASM degrade; that is the point of raising the slider.
            try {
                var __origGetCtx = HTMLCanvasElement.prototype.getContext;
                HTMLCanvasElement.prototype.getContext = mask(function(type) {
                    var t = String(type || '').toLowerCase();
                    if (t.indexOf('webgl') >= 0 || t === 'webgpu') { return null; }
                    return __origGetCtx.apply(this, arguments);
                }, 'getContext');
                try { Object.defineProperty(window, 'WebAssembly', { get: mask(function(){ return undefined; }, 'get WebAssembly'), configurable: true }); } catch (e) {}
            } catch (e) {}
        """ : ""
        return """
        try {
            var __dnsMeta = document.createElement('meta');
            __dnsMeta.httpEquiv = 'x-dns-prefetch-control'; __dnsMeta.content = 'off';
            (document.head || document.documentElement).appendChild(__dnsMeta);
            var __specRel = /(^|\\s)(dns-prefetch|preconnect|prefetch|prerender)(\\s|$)/i;
            function __stripSpec(node) {
                try {
                    if (node.tagName === 'LINK' && __specRel.test(node.getAttribute('rel') || '')) {
                        if (node.parentNode) { node.parentNode.removeChild(node); } return;
                    }
                    if (node.querySelectorAll) {
                        node.querySelectorAll('link[rel]').forEach(function (l) {
                            if (__specRel.test(l.getAttribute('rel') || '')) { try { l.parentNode && l.parentNode.removeChild(l); } catch (e) {} }
                        });
                    }
                } catch (e) {}
            }
            __stripSpec(document);
            try {
                var __specMO = new MutationObserver(function (muts) {
                    for (var i = 0; i < muts.length; i++) {
                        var an = muts[i].addedNodes || [];
                        for (var j = 0; j < an.length; j++) { if (an[j].nodeType === 1) { __stripSpec(an[j]); } }
                    }
                });
                __specMO.observe(document.documentElement || document, { childList: true, subtree: true });
            } catch (e) {}
        } catch (e) {}

        try {
            defGet(Navigator.prototype, 'language', function () { return 'en-US'; });
            Object.defineProperty(Navigator.prototype, 'languages', { get: mask(function () { return ['en-US', 'en']; }, 'get languages'), configurable: true });
        } catch (e) {}

        // Timing side-channel + fingerprint defense: coarsen the high-resolution timer to 100ms and drop
        // the SharedArrayBuffer nanosecond-timer primitive — blunts Spectre-class cross-origin reads AND
        // high-resolution timing fingerprinting (the standard Tor Browser mitigation).
        try {
            if (window.performance && performance.now) {
                var __origPerfNow = performance.now.bind(performance);
                performance.now = mask(function () { return Math.floor(__origPerfNow() / 100) * 100; }, 'now');
            }
            try { Object.defineProperty(window, 'SharedArrayBuffer', { get: mask(function () { return undefined; }, 'get SharedArrayBuffer'), configurable: true }); } catch (e) {}
            try { Object.defineProperty(window, 'crossOriginIsolated', { get: mask(function () { return false; }, 'get crossOriginIsolated'), configurable: true }); } catch (e) {}
        } catch (e) {}

        // speechSynthesis voice list leaks the installed TTS voices — a stable fingerprint. Report none.
        try {
            if (window.speechSynthesis && speechSynthesis.getVoices) {
                speechSynthesis.getVoices = mask(function () { return []; }, 'getVoices');
            }
        } catch (e) {}

        // Close the Web Worker fingerprinting bypass: a page can move OffscreenCanvas / WebGL / audio reads
        // into a worker, where the main-thread farbling doesn't reach, and read a CLEAN fingerprint. Wrap
        // the classic Worker / SharedWorker constructors so the real script is prefixed (via importScripts
        // from a same-origin blob) with worker-scope farbling. Module workers can't importScripts, so they
        // fall back — a documented WKWebView limit.
        try {
            var __wfarble = \(Self.workerFarblingLiteral);
            function __wrapWorker(Orig) {
                if (!Orig) { return Orig; }
                var Wrapped = function (url, options) {
                    try {
                        if (options && options.type === 'module') { return new Orig(url, options); }
                        var real = (new URL(String(url), location.href)).href;
                        var shim = __wfarble + ';try{importScripts(' + JSON.stringify(real) + ');}catch(e){}';
                        var blobUrl = URL.createObjectURL(new Blob([shim], { type: 'application/javascript' }));
                        return new Orig(blobUrl, options);
                    } catch (e) { return new Orig(url, options); }
                };
                try { Wrapped.prototype = Orig.prototype; } catch (e) {}
                return mask(Wrapped, 'Worker');
            }
            if (window.Worker) { window.Worker = __wrapWorker(window.Worker); }
            if (window.SharedWorker) { window.SharedWorker = __wrapWorker(window.SharedWorker); }
        } catch (e) {}

        \(saferBlock)
        """
    }

    /// Worker-scope farbling (self-contained — no dependency on the main-thread IIFE's `mask`/`defGet`),
    /// prepended to classic workers by the Worker wrapper in strictMaximumHardeningJS so OffscreenCanvas /
    /// WebGL reads and the high-res timer are farbled inside workers too (closing the Worker FP bypass).
    static let workerFarblingSource: String = """
    (function(){
    'use strict';
    function cb(v){return v<0?0:(v>255?255:v);}
    function jt(){return (Math.random()<0.5)?-1:1;}
    try { if (self.performance && self.performance.now) { var pn = self.performance.now.bind(self.performance); self.performance.now = function(){ return Math.floor(pn()/100)*100; }; } } catch(e){}
    try { Object.defineProperty(self,'SharedArrayBuffer',{get:function(){return undefined;},configurable:true}); } catch(e){}
    try { if (self.OffscreenCanvasRenderingContext2D) { var g=OffscreenCanvasRenderingContext2D.prototype.getImageData; OffscreenCanvasRenderingContext2D.prototype.getImageData=function(){var img=g.apply(this,arguments);try{var d=img.data;for(var i=0;i<d.length;i+=256){d[i]=cb(d[i]+jt());}}catch(e){}return img;}; } } catch(e){}
    try { function pg(p){ if(!p)return; var gp=p.getParameter; p.getParameter=function(x){ if(x===37445)return 'Apple Inc.'; if(x===37446)return 'Apple GPU'; return gp.apply(this,arguments); }; var rp=p.readPixels; p.readPixels=function(){ rp.apply(this,arguments); try{var b=arguments[6]; if(b&&b.length){ for(var i=0;i<b.length;i+=503){ b[i]=b[i]^1; } }}catch(e){} }; } if (self.WebGLRenderingContext) pg(self.WebGLRenderingContext.prototype); if (self.WebGL2RenderingContext) pg(self.WebGL2RenderingContext.prototype); } catch(e){}
    })();
    """

    /// `workerFarblingSource` as a safely-escaped JS string literal for interpolation into the wrapper.
    static var workerFarblingLiteral: String {
        if let data = try? JSONSerialization.data(withJSONObject: workerFarblingSource, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\"\""
    }

    /// Local SOCKS5 endpoint for the bundled Tor client. Shared by onion tabs and Maximum-Privacy+Tor
    /// routing so both reach Tor the same way (SOCKS5h — hostnames resolved at the proxy, no DNS leak).
    static func torSocksEndpoint() -> NWEndpoint {
        NWEndpoint.hostPort(
            host: NWEndpoint.Host(TorRuntimeConfig.socksHost),
            port: NWEndpoint.Port(rawValue: TorRuntimeConfig.socksPort) ?? 19050
        )
    }

    /// A Tor SOCKS proxy config carrying a fresh per-tab isolation token (Searxly Maximum only). Tor
    /// treats the SOCKS username/password purely as a stream-isolation key (`IsolateSOCKSAuth`, which is
    /// Tor's default), so a distinct pair gets a distinct circuit. Giving every tab its own token means
    /// two tabs open on the SAME site no
    /// longer share a Tor circuit, so a shared exit can't correlate them as one client — it closes the
    /// same-origin cross-tab linkage that per-destination isolation alone leaves open. The token is an
    /// opaque nonce, never a secret, and is fixed for the tab's lifetime (New Identity still rotates it).
    static func makeTorProxyConfiguration() -> ProxyConfiguration {
        let config = ProxyConfiguration(socksv5Proxy: torSocksEndpoint())
        // Per-tab circuit isolation is a Searxly Maximum edition feature. The base app's onion/Tor tabs
        // use a plain, credential-less proxy (shared circuit per destination) exactly as before.
        if Edition.isMaximum {
            let token = UUID().uuidString
            config.applyCredential(username: token, password: token)
        }
        return config
    }

    /// Routes a tab through Tor's local SOCKS proxy and applies the onion IP-leak hardening (WebRTC /
    /// media-device / geolocation neutering). Used for Maximum Privacy + Tor so standard and private
    /// tabs traverse Tor exactly like onion tabs, hiding the real IP. Forces a non-persistent store.
    @MainActor
    static func applyTorRouting(to configuration: WKWebViewConfiguration) {
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [Self.makeTorProxyConfiguration()]
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
