//
//  TrackerTally.swift
//  SearxlyiOS
//
//  The visible half of the shields: a live "trackers blocked" count per page. WKContentRuleList
//  blocks silently (no callbacks), so we count ATTEMPTS instead: an early user script hooks the
//  ways pages issue requests (fetch, XHR, and src-carrying elements via MutationObserver) and
//  reports hits against a compact set of the highest-volume tracker domains — the same domains
//  the bundled EasyPrivacy/Peter Lowe rules actually block. Approximate by design: a floor on
//  the real number, never an exact audit. Nothing leaves the device.
//

import Foundation
import WebKit

@MainActor
enum TrackerTally {

    nonisolated static let messageHandlerName = "searxlyTrackerTally"

    static func apply(to configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        guard ShieldSettings.shared.blockAdsAndTrackers else { return }
        configuration.userContentController.add(handler, name: messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: tallyJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
    }

    /// High-volume tracker/ad hosts (suffix-matched). Kept small on purpose — these are the
    /// domains behind the overwhelming majority of tracking requests on the web.
    private static let trackerDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "admob.com",
        "facebook.net", "connect.facebook.com", "graph.facebook.com", "fbcdn.net",
        "adnxs.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "outbrainimg.com",
        "scorecardresearch.com", "quantserve.com", "quantcount.com", "chartbeat.com", "parsely.com",
        "hotjar.com", "hotjar.io", "mouseflow.com", "fullstory.com", "clarity.ms", "mixpanel.com",
        "segment.io", "segment.com", "amplitude.com", "branch.io", "adjust.com", "appsflyer.com",
        "kochava.com", "singular.net", "sentry.io", "bugsnag.com", "newrelic.com", "nr-data.net",
        "amazon-adsystem.com", "adsystem.amazon.com", "media.net", "pubmatic.com", "rubiconproject.com",
        "openx.net", "casalemedia.com", "indexww.com", "smartadserver.com", "adform.net",
        "yieldmo.com", "sharethrough.com", "triplelift.com", "33across.com", "gumgum.com",
        "moatads.com", "adsafeprotected.com", "doubleverify.com", "serving-sys.com", "sizmek.com",
        "bluekai.com", "krxd.net", "exelator.com", "demdex.net", "omtrdc.net", "everesttech.net",
        "mathtag.com", "turn.com", "rlcdn.com", "agkn.com", "eyeota.net", "tapad.com",
        "bidswitch.net", "id5-sync.com", "adsrvr.org", "advertising.com", "yahoo.com/pixel",
        "ads.yahoo.com", "analytics.yahoo.com", "ads.tiktok.com", "analytics.tiktok.com",
        "ads.twitter.com", "static.ads-twitter.com", "analytics.twitter.com", "ads.linkedin.com",
        "px.ads.linkedin.com", "snap.licdn.com", "ads.pinterest.com", "ct.pinterest.com",
        "ads.reddit.com", "events.redditmedia.com", "hs-analytics.net", "hs-scripts.com",
        "hubspot.com/analytics", "marketo.net", "mktoresp.com", "pardot.com", "eloqua.com",
        "crazyegg.com", "optimizely.com", "vwo.com", "visualwebsiteoptimizer.com", "kissmetrics.io",
        "heapanalytics.com", "matomo.cloud", "plausible.io/api/event", "yandex.ru/metrika",
        "mc.yandex.ru", "adriver.ru", "criteo.com", "smaato.net", "inmobi.com", "unityads.unity3d.com",
        "vungle.com", "applovin.com", "ironsrc.com", "supersonicads.com", "chartboost.com",
        "tapjoy.com", "mopub.com", "onesignal.com", "braze.com", "airship.com", "urbanairship.com",
        "cdn.ampproject.org/v0/amp-analytics", "bounceexchange.com", "bouncex.net", "wunderkind.co",
        "permutive.com", "piano.io", "cxense.com", "comscore.com", "nielsen.com", "imrworldwide.com",
        "adition.com", "teads.tv", "stickyadstv.com", "spotxchange.com", "spotx.tv",
        "freewheel.tv", "innovid.com", "undertone.com", "zemanta.com", "revcontent.com",
        "mgid.com", "adblade.com", "contentad.net", "zergnet.com",
    ]

    private static var tallyJS: String {
        let domainsJSON = (try? String(data: JSONEncoder().encode(trackerDomains), encoding: .utf8)) ?? "[]"
        return """
        (function() {
            'use strict';
            if (window.__searxlyTallyInstalled) return;
            window.__searxlyTallyInstalled = true;

            var DOMAINS = \(domainsJSON);
            var pending = 0, scheduled = false, seen = {}, pendingDomains = {};

            function flush() {
                scheduled = false;
                if (pending > 0) {
                    var n = pending; pending = 0;
                    var d = Object.keys(pendingDomains); pendingDomains = {};
                    try { window.webkit.messageHandlers.\(messageHandlerName).postMessage({c: n, d: d}); } catch (e) {}
                }
            }
            function report(matchedDomain) {
                pending += 1;
                if (matchedDomain) { pendingDomains[matchedDomain] = 1; }
                if (!scheduled) { scheduled = true; setTimeout(flush, 400); }
            }
            function hostOf(url) {
                try { return new URL(url, location.href).host.toLowerCase(); } catch (e) { return ''; }
            }
            function matchTracker(url) {
                if (!url) return null;
                var h = hostOf(String(url));
                if (!h) return null;
                for (var i = 0; i < DOMAINS.length; i++) {
                    var d = DOMAINS[i];
                    if (d.indexOf('/') !== -1) {
                        if (String(url).indexOf(d) !== -1) return d.split('/')[0];
                    } else if (h === d || h.endsWith('.' + d)) {
                        return d;
                    }
                }
                return null;
            }
            function check(url) {
                var key = String(url);
                if (seen[key]) return;
                var match = matchTracker(url);
                if (match) { seen[key] = 1; report(match); }
            }

            try {
                var origFetch = window.fetch;
                if (origFetch) {
                    window.fetch = function(input) {
                        try { check(input && input.url ? input.url : input); } catch (e) {}
                        return origFetch.apply(this, arguments);
                    };
                }
            } catch (e) {}

            try {
                var origOpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    try { check(url); } catch (e) {}
                    return origOpen.apply(this, arguments);
                };
            } catch (e) {}

            try {
                var origBeacon = navigator.sendBeacon;
                if (origBeacon) {
                    navigator.sendBeacon = function(url) {
                        try { check(url); } catch (e) {}
                        return origBeacon.apply(this, arguments);
                    };
                }
            } catch (e) {}

            try {
                new MutationObserver(function(mutations) {
                    for (var i = 0; i < mutations.length; i++) {
                        var m = mutations[i];
                        if (m.type === 'attributes' && m.target && m.target.src) {
                            check(m.target.src);
                        } else if (m.addedNodes) {
                            for (var j = 0; j < m.addedNodes.length; j++) {
                                var node = m.addedNodes[j];
                                if (node && node.src) check(node.src);
                            }
                        }
                    }
                }).observe(document.documentElement, {
                    childList: true, subtree: true, attributes: true, attributeFilter: ['src']
                });
            } catch (e) {}
        })();
        """
    }
}
