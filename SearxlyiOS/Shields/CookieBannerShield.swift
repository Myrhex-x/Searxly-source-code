//
//  CookieBannerShield.swift
//  SearxlyiOS
//
//  Hides cookie-consent / GDPR banners and their scroll-locking overlays — the "annoyances"
//  layer on top of the ad/tracker shields. A compact, conservative user script: it targets
//  well-known Consent-Management-Platform containers (OneTrust, Quantcast, Cookiebot, Didomi,
//  TrustArc, Osano, Usercentrics, Sourcepoint…) and generic consent wrappers, and — crucially —
//  restores scrolling that these overlays disable. It NEVER auto-clicks "Accept" (that would
//  opt the user IN); it just removes the nag. GPC + Do-Not-Sell already signal preference.
//

import Foundation
import WebKit

@MainActor
enum CookieBannerShield {

    static func apply(to configuration: WKWebViewConfiguration) {
        guard ShieldSettings.shared.blockCookieBanners else { return }
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    private static let script = """
    (function() {
        'use strict';
        if (window.__searxlyCookieShield) return;
        window.__searxlyCookieShield = true;

        // Known CMP containers + generic consent wrappers. Conservative: id/class substrings
        // strongly associated with consent UI, not content.
        var SELECTORS = [
            '#onetrust-consent-sdk', '#onetrust-banner-sdk', '.onetrust-pc-dark-filter',
            '#qc-cmp2-container', '.qc-cmp2-container', '.qc-cmp-cleanslate',
            '#CybotCookiebotDialog', '#CybotCookiebotDialogBodyUnderlay',
            '#didomi-host', '.didomi-popup-open', '#didomi-notice',
            '#truste-consent-track', '.truste_overlay', '.truste_box_overlay',
            '.osano-cm-window', '.osano-cm-dialog',
            '#usercentrics-root', '[id^="usercentrics"]',
            '.sp_message_container', '[id^="sp_message_container"]', '.sp-message-open',
            '#cmpbox', '#cmpwrapper', '.cmp-container',
            '.fc-consent-root', '.fc-dialog-overlay',
            '#gdpr-consent-tool-wrapper', '.gdpr-modal', '.gdpr-overlay',
            '[aria-label*="cookie" i][role="dialog"]', '[aria-describedby*="cookie" i]',
            '.cookie-consent', '.cookie-banner', '.cookie-notice', '#cookie-banner',
            '#cookie-notice', '.cookie-law-info-bar', '#cookie-law-info-bar',
            '.cc-window', '.cc-banner', '.js-consent-banner', '#consent-banner',
            '.consent-banner', '.consent-modal', '.privacy-banner', '#privacy-banner'
        ];

        function purge() {
            for (var i = 0; i < SELECTORS.length; i++) {
                var nodes;
                try { nodes = document.querySelectorAll(SELECTORS[i]); } catch (e) { continue; }
                for (var j = 0; j < nodes.length; j++) {
                    var el = nodes[j];
                    // Skip anything that clearly wraps the whole page (avoid nuking body content).
                    if (el === document.body || el === document.documentElement) continue;
                    el.style.setProperty('display', 'none', 'important');
                }
            }
            // These overlays commonly lock scrolling — give it back.
            var html = document.documentElement, body = document.body;
            [html, body].forEach(function(node) {
                if (!node) return;
                if (node.style.overflow === 'hidden') node.style.setProperty('overflow', 'auto', 'important');
                node.style.removeProperty('position');
                node.classList.remove('sp-message-open', 'didomi-popup-open', 'modal-open',
                                       'no-scroll', 'noscroll', 'overflow-hidden', 'cmp-noscroll');
            });
        }

        purge();
        // Late/SPA-injected banners: a few timed sweeps + a bounded observer.
        var count = 0;
        var iv = setInterval(function() { purge(); if (++count > 12) clearInterval(iv); }, 400);
        try {
            new MutationObserver(function() { purge(); })
                .observe(document.documentElement, { childList: true, subtree: true });
        } catch (e) {}
    })();
    """
}
