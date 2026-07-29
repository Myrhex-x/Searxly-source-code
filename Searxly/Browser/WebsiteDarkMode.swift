//
//  WebsiteDarkMode.swift
//  Searxly
//
//  First of the "native ported features" — Searxly-built equivalents of popular open-source extensions,
//  run as first-party content scripts instead of through the (currently unreliable) WebExtension engine.
//  This one is a clean-room "dark mode for websites": it darkens light pages you visit and leaves
//  already-dark ones alone. Reimplemented from scratch (no third-party code) so there's no licensing
//  entanglement — same idea as Dark Reader's simple "filter" mode.
//
//  Injected as a `WKUserScript` on STANDARD tabs only (never Private/Onion), mirroring AdBlockManager /
//  YouTubeAdBlocker. Toggle lives in Settings → Appearance. Changes apply to new tabs immediately and to
//  open tabs after a reload (WKUserScripts are fixed at webview creation).
//

import WebKit

@MainActor
final class WebsiteDarkMode {
    static let shared = WebsiteDarkMode()
    private init() {}

    static let defaultsKey = "websiteDarkModeEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    /// Adds the dark-mode content script to a standard-tab configuration when the feature is on.
    func apply(to configuration: WKWebViewConfiguration, mode: TabPrivacyMode) {
        guard isEnabled, mode == .standard else { return }
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    /// The injected content script. Main frame only. Skips pages that are already dark (so a dark site
    /// isn't inverted back to light), then applies an invert + hue-rotate filter to the document and
    /// re-inverts media (images/video/etc.) so photos stay true-colour — the well-known robust approach.
    private static let source = """
    (function () {
      'use strict';
      if (window.top !== window) { return; }
      var STYLE_ID = '__searxly_dark_mode';
      try {
        if (document.getElementById(STYLE_ID)) { return; }
        // Don't darken pages that are already dark.
        var probe = document.body || document.documentElement;
        var bg = getComputedStyle(probe).backgroundColor || '';
        var m = bg.match(/\\d+/g);
        if (m && m.length >= 3) {
          var lum = 0.299 * (+m[0]) + 0.587 * (+m[1]) + 0.114 * (+m[2]);
          if (lum < 105) { return; }
        }
        var css =
          'html{filter:invert(1) hue-rotate(180deg)!important;background:#1b1b1b!important}' +
          'img,video,picture,canvas,svg,iframe,embed,object,[style*="background-image"],' +
          '[data-searxly-media]{filter:invert(1) hue-rotate(180deg)!important}';
        var style = document.createElement('style');
        style.id = STYLE_ID;
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      } catch (e) {}
    })();
    """
}
