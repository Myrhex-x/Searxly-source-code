//
//  WebsiteDarkMode.swift
//  SearxlyiOS
//
//  "Dark mode for websites" — the iOS twin of the macOS content script (clean-room, no
//  third-party code): darkens light pages and leaves already-dark ones alone via the classic
//  invert + hue-rotate filter, re-inverting media so photos stay true-colour.
//
//  Injected as a WKUserScript at webview creation (BrowserModel.makeConfiguration), so new tabs
//  pick a toggle flip up immediately and open tabs after a reload. Gated by
//  ShieldSettings.websiteDarkMode (Settings ▸ Appearance, default off).
//

import WebKit

@MainActor
enum WebsiteDarkMode {

    /// Adds the dark-mode content script when the setting is on.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard ShieldSettings.shared.websiteDarkMode else { return }
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
    }

    /// Same script as the macOS WebsiteDarkMode: skip pages that are already dark, then invert.
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
