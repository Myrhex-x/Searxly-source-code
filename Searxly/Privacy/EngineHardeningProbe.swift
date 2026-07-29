//
//  EngineHardeningProbe.swift
//  Searxly
//
//  Behavioral verification for the Privacy Self-Test: instead of trusting that hardening was
//  CONFIGURED, build a scratch web view through the exact same factory path as a real tab, load a
//  blank in-memory page (no network — safe even with the kill switch armed), and observe what a
//  page's JavaScript actually sees. This is the runtime check MAXIMUM-HARDENING.md calls for: the
//  engine-level SPI toggles can silently miss on a future WebKit (they fail safe to the JS shims),
//  and a probe is the only way to know what landed on THIS system.
//
//  The probe reports raw observations; PrivacySelfTest decides what each one must be, because the
//  expectations differ by edition (timer coarsening / locale pinning / voices are Searxly Maximum
//  only) and by security level (WebGL / WASM must be gone at Safer+, present at Standard).
//

import Foundation
import WebKit

@MainActor
enum EngineHardeningProbe {

    /// What a page's JavaScript observed in a freshly built tab-equivalent web view.
    struct Observations {
        let webrtcAbsent: Bool           // RTCPeerConnection (and webkit- prefix) unreachable
        let sharedArrayBufferAbsent: Bool
        let language: String             // navigator.language as the page reads it
        let timezoneOffset: Int          // Date.getTimezoneOffset() — 0 when masked to UTC
        let voicesEmpty: Bool            // speechSynthesis.getVoices() enumerates nothing
        let timerCoarsened: Bool         // performance.now() lands on 100 ms buckets
        let webglAvailable: Bool
        let wasmAvailable: Bool
        let pluginsEmpty: Bool           // navigator.plugins emptied (no Chromium PDF names under the Safari UA)
        let cores: Int                   // navigator.hardwareConcurrency as the page reads it (pinned to 8)
    }

    /// Build a scratch standard-tab web view, load a blank document, and read the observations.
    /// Returns nil if the page never finished loading or the script failed — callers must surface
    /// that as "couldn't verify", never as a pass.
    static func observe() async -> Observations? {
        let webView = WebViewFactory.makeWebView(mode: .standard)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiter.continuation = continuation
            // The blank document still runs every injected WKUserScript at document start, and the
            // web view carries the engine-level preferences — exactly what a real page would get.
            webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                waiter.continuation?.resume(returning: false)
                waiter.continuation = nil
            }
        }
        guard loaded else { return nil }

        guard let result = try? await webView.evaluateJavaScript(Self.probeScript),
              let dict = result as? [String: Any] else { return nil }
        // Keep the delegate alive through the load + evaluation.
        withExtendedLifetime(waiter) {}

        func flag(_ key: String) -> Bool { (dict[key] as? Bool) ?? (dict[key] as? NSNumber)?.boolValue ?? false }
        return Observations(
            webrtcAbsent: flag("webrtcAbsent"),
            sharedArrayBufferAbsent: flag("sabAbsent"),
            language: (dict["lang"] as? String) ?? "",
            timezoneOffset: (dict["tzOffset"] as? NSNumber)?.intValue ?? Int.min,
            voicesEmpty: flag("voicesEmpty"),
            timerCoarsened: flag("timerCoarse"),
            webglAvailable: flag("webgl"),
            wasmAvailable: flag("wasm"),
            pluginsEmpty: flag("pluginsEmpty"),
            cores: (dict["cores"] as? NSNumber)?.intValue ?? -1
        )
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Bool, Never>?
        private func finish(_ ok: Bool) {
            continuation?.resume(returning: ok)
            continuation = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }

    /// Reads each surface the way a fingerprinting page would. The timer check exploits the exact
    /// coarsening implementation (floor to 100 ms buckets ⇒ every reading is a multiple of 100);
    /// three consecutive multiples by chance on an unmasked timer is ~1 in 10^6.
    private static let probeScript = """
    (function () {
        function hasCtx(kind) {
            try { return !!document.createElement('canvas').getContext(kind); } catch (e) { return false; }
        }
        var timerCoarse = false;
        try {
            timerCoarse = (performance.now() % 100 === 0)
                       && (performance.now() % 100 === 0)
                       && (performance.now() % 100 === 0);
        } catch (e) {}
        var voicesEmpty = true;
        try { if (window.speechSynthesis && speechSynthesis.getVoices) { voicesEmpty = speechSynthesis.getVoices().length === 0; } } catch (e) {}
        return {
            webrtcAbsent: (typeof RTCPeerConnection === 'undefined') && (typeof webkitRTCPeerConnection === 'undefined'),
            sabAbsent: typeof SharedArrayBuffer === 'undefined',
            lang: String(navigator.language || ''),
            tzOffset: new Date().getTimezoneOffset(),
            voicesEmpty: voicesEmpty,
            timerCoarse: timerCoarse,
            webgl: hasCtx('webgl') || hasCtx('webgl2'),
            wasm: typeof WebAssembly !== 'undefined',
            pluginsEmpty: (function () { try { return !navigator.plugins || navigator.plugins.length === 0; } catch (e) { return false; } })(),
            cores: (navigator.hardwareConcurrency | 0)
        };
    })()
    """
}
