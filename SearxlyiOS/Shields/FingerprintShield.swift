//
//  FingerprintShield.swift
//  SearxlyiOS
//
//  Brave-style fingerprint randomization for WKWebView: canvas and audio farbling keyed to a
//  per-session random seed (a new identity every launch, consistent within the session so sites
//  don't see "noise flicker"), plus stable hardware clamps. WKWebView can't fully solve
//  fingerprinting (honest ceiling — same as macOS), but these defeat the common canvas/audio
//  hash libraries (fingerprintjs et al).
//

import Foundation
import WebKit

@MainActor
enum FingerprintShield {

    /// One random seed per app session.
    private static let sessionSeed = UInt32.random(in: 1...UInt32.max)

    static func apply(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController

        // Always-on: clamp hardwareConcurrency (moved here from BrowserModel).
        controller.addUserScript(
            WKUserScript(source: hardwareClampJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        if ShieldSettings.shared.fingerprintProtection {
            controller.addUserScript(
                WKUserScript(source: farblingJS(seed: sessionSeed), injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        if ShieldSettings.shared.gpcSignal {
            controller.addUserScript(
                WKUserScript(source: gpcJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
    }

    private static let hardwareClampJS = """
    (function() {
        'use strict';
        try {
            var cores = Math.min((navigator.hardwareConcurrency | 0) || 8, 8);
            Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', {
                get: function () { return cores; }, enumerable: true, configurable: true
            });
        } catch (e) {}
    })();
    """

    /// navigator.globalPrivacyControl — the JS half of GPC (the Sec-GPC header is added by
    /// the navigation guard on main-frame requests).
    private static let gpcJS = """
    (function() {
        'use strict';
        try {
            Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {
                get: function () { return true; }, enumerable: true, configurable: true
            });
        } catch (e) {}
    })();
    """

    /// Canvas + audio farbling. Deterministic tiny noise from the session seed: canvas reads get
    /// sub-perceptual pixel perturbation; AnalyserNode/AudioBuffer reads get ±1e-5 jitter.
    private static func farblingJS(seed: UInt32) -> String {
        """
        (function() {
            'use strict';
            var SEED = \(seed);
            function mulberry32(a) {
                return function() {
                    a |= 0; a = a + 0x6D2B79F5 | 0;
                    var t = Math.imul(a ^ a >>> 15, 1 | a);
                    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
                    return ((t ^ t >>> 14) >>> 0) / 4294967296;
                };
            }

            // ── Canvas farbling ─────────────────────────────────────────────────────
            try {
                var perturb = function(data) {
                    // Flip the low bit of a sparse, seed-chosen subset of channel bytes.
                    var rand = mulberry32(SEED ^ data.length);
                    var step = 512 + Math.floor(rand() * 512);
                    for (var i = Math.floor(rand() * step); i < data.length; i += step) {
                        data[i] = data[i] ^ 1;
                    }
                };
                var origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
                CanvasRenderingContext2D.prototype.getImageData = function() {
                    var image = origGetImageData.apply(this, arguments);
                    try { perturb(image.data); } catch (e) {}
                    return image;
                };
                var farbleViaContext = function(canvas) {
                    try {
                        var ctx = canvas.getContext('2d');
                        if (ctx && canvas.width > 0 && canvas.height > 0) {
                            var img = origGetImageData.call(ctx, 0, 0, canvas.width, canvas.height);
                            perturb(img.data);
                            ctx.putImageData(img, 0, 0);
                        }
                    } catch (e) {}
                };
                var origToDataURL = HTMLCanvasElement.prototype.toDataURL;
                HTMLCanvasElement.prototype.toDataURL = function() {
                    farbleViaContext(this);
                    return origToDataURL.apply(this, arguments);
                };
                var origToBlob = HTMLCanvasElement.prototype.toBlob;
                HTMLCanvasElement.prototype.toBlob = function() {
                    farbleViaContext(this);
                    return origToBlob.apply(this, arguments);
                };
            } catch (e) {}

            // ── Audio farbling ──────────────────────────────────────────────────────
            try {
                var AC = window.AudioContext || window.webkitAudioContext;
                if (AC) {
                    var jitter = function(arr) {
                        var rand = mulberry32(SEED ^ 0xA0D10);
                        for (var i = 0; i < arr.length; i += 100) {
                            arr[i] = arr[i] + (rand() - 0.5) * 2e-5;
                        }
                    };
                    if (window.AnalyserNode) {
                        var origFloatFreq = AnalyserNode.prototype.getFloatFrequencyData;
                        AnalyserNode.prototype.getFloatFrequencyData = function(array) {
                            origFloatFreq.call(this, array);
                            jitter(array);
                        };
                    }
                    if (window.AudioBuffer) {
                        var origChannel = AudioBuffer.prototype.getChannelData;
                        AudioBuffer.prototype.getChannelData = function() {
                            var data = origChannel.apply(this, arguments);
                            if (!data.__searxlyFarbled) {
                                try { jitter(data); data.__searxlyFarbled = true; } catch (e) {}
                            }
                            return data;
                        };
                    }
                }
            } catch (e) {}
        })();
        """
    }
}
