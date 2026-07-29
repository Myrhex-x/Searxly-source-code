//
//  PageTranslator.swift
//  SearxlyiOS
//
//  Full-page translation via Apple's Translation framework — entirely ON-DEVICE, the iOS twin of
//  the macOS PageTranslator. No page text ever leaves the device: the framework runs local models
//  (iOS downloads a language pack from Apple the first time a pair is used — a system asset fetch,
//  never the page content).
//
//  Per translate: a JS pass collects visible text nodes (stashing originals page-side for
//  restore), the strings run through a TranslationSession in batches, and each finished batch is
//  injected straight back so the page translates progressively. "Show Original" restores without
//  a reload. BrowserView owns the `.translationTask` that provides the session.
//

import Foundation
import WebKit
import Observation
import Translation

@MainActor
@Observable
final class PageTranslator {
    static let shared = PageTranslator()

    /// Non-nil kicks off BrowserView's `.translationTask`, which calls `run(_:)` with a session.
    private(set) var configuration: TranslationSession.Configuration?

    /// The webview the pending/last run targets. Weak: a closed tab must not be retained here.
    private weak var targetWebView: WKWebView?

    /// Webview → URL it was translated on. A navigation makes the entry stale (URLs differ), so
    /// the menu's "Show Original" label resets to "Translate Page" without lifecycle hooks.
    private let translatedURLs = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

    private(set) var isTranslating = false

    /// Set on failure; BrowserView surfaces it as an alert and clears it.
    var failureMessage: String?

    private init() {}

    // MARK: - Public surface (page menu)

    /// Whether this webview is currently showing translations for the page it's on.
    func isTranslated(_ webView: WKWebView?) -> Bool {
        guard let webView, let url = webView.url else { return false }
        return translatedURLs.object(forKey: webView) as URL? == url
    }

    /// Menu action: translate the page, or restore the original if it's already translated.
    func toggleTranslation(for webView: WKWebView) {
        if isTranslated(webView) {
            showOriginal(in: webView)
        } else {
            beginTranslation(of: webView)
        }
    }

    /// Restores every translated node's remembered original text (no reload).
    func showOriginal(in webView: WKWebView) {
        translatedURLs.removeObject(forKey: webView)
        webView.evaluateJavaScript(Self.restoreScript, completionHandler: nil)
    }

    // MARK: - Run lifecycle

    private func beginTranslation(of webView: WKWebView) {
        guard !isTranslating, webView.url != nil else { return }
        targetWebView = webView

        // Target = the app's content language (Settings ▸ Language ▸ Search Results, falling back
        // to the active app/system language). Source nil → the framework detects the page itself.
        let target = Locale.Language(identifier: SearchSettings.shared.resolvedContentLanguage)

        // A first/changed configuration fires on assignment; an identical pair needs
        // `invalidate()` to run again (Apple's documented pattern).
        if configuration == nil || configuration?.target != target {
            configuration = TranslationSession.Configuration(source: nil, target: target)
        } else {
            configuration?.invalidate()
        }
    }

    /// Called by BrowserView's `.translationTask` with a live session. Collects, translates in
    /// batches, and injects progressively.
    func run(_ session: TranslationSession) async {
        guard let webView = targetWebView else { return }
        isTranslating = true
        defer { isTranslating = false }

        // 1. Collect the page's translatable text (and stash originals page-side for restore).
        let strings = await collectStrings(from: webView)
        guard !strings.isEmpty else {
            failureMessage = L("There's no translatable text on this page.")
            return
        }

        // 2. Translate in batches, injecting each as it completes so the page flips progressively.
        var appliedAny = false
        do {
            // Download the language pack up-front if needed (the framework shows its own consent UI).
            try? await session.prepareTranslation()

            let batchSize = 100
            for start in stride(from: 0, to: strings.count, by: batchSize) {
                let end = min(start + batchSize, strings.count)
                let requests = (start..<end).map {
                    TranslationSession.Request(sourceText: strings[$0], clientIdentifier: String($0))
                }
                let responses = try await session.translations(from: requests)

                var pairs: [[Any]] = []
                for response in responses {
                    guard let id = response.clientIdentifier, let index = Int(id) else { continue }
                    pairs.append([index, response.targetText])
                }
                if await apply(pairs: pairs, to: webView) { appliedAny = true }
            }
        } catch {
            guard !appliedAny else {   // partial page is still useful — keep it, stay "translated"
                if let url = webView.url { translatedURLs.setObject(url as NSURL, forKey: webView) }
                return
            }
            // Most common real cause: the page is already in the target language.
            failureMessage = L("Couldn't translate this page — it may already be in your language, or the language pair isn't supported on-device.")
            return
        }

        if appliedAny, let url = webView.url {
            translatedURLs.setObject(url as NSURL, forKey: webView)
        } else {
            failureMessage = L("There's no translatable text on this page.")
        }
    }

    // MARK: - Page JS (same scripts as the macOS PageTranslator)

    /// Runs the collection pass; returns the strings (empty on any failure).
    private func collectStrings(from webView: WKWebView) async -> [String] {
        let result = try? await webView.evaluateJavaScript(Self.collectScript)
        guard let json = result as? String, let data = json.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings
    }

    /// Injects one batch of `[index, translatedText]` pairs. Returns true when at least one applied.
    private func apply(pairs: [[Any]], to webView: WKWebView) async -> Bool {
        guard !pairs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: pairs) else { return false }
        // base64 + TextDecoder (NOT bare atob) so non-ASCII translations survive the crossing.
        let b64 = data.base64EncodedString()
        let js = "(\(Self.applyFunction))('\(b64)')"
        let applied = try? await webView.evaluateJavaScript(js)
        return ((applied as? Int) ?? 0) > 0
    }

    /// Walks visible text nodes, stashes node refs + originals in `window.__searxlyTx`, returns
    /// a JSON array of their strings. Skips code/editable content; caps size so a pathological
    /// page can't queue an hour of model work.
    private static let collectScript = #"""
    (function () {
      try {
        if (!document.body) return "[]";
        var S = window.__searxlyTx = window.__searxlyTx || {};
        S.nodes = []; S.originals = []; S.on = false;
        var SKIP = { SCRIPT:1, STYLE:1, NOSCRIPT:1, TEMPLATE:1, TEXTAREA:1, CODE:1, PRE:1, KBD:1, SAMP:1 };
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function (n) {
            var p = n.parentElement;
            if (!p || SKIP[p.nodeName]) return NodeFilter.FILTER_REJECT;
            if (p.isContentEditable) return NodeFilter.FILTER_REJECT;
            var t = n.nodeValue;
            if (!t || t.trim().length < 2) return NodeFilter.FILTER_SKIP;
            if (!/[\p{L}]/u.test(t)) return NodeFilter.FILTER_SKIP;
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var n, count = 0, chars = 0;
        while ((n = walker.nextNode()) && count < 2500 && chars < 150000) {
          S.nodes.push(n); S.originals.push(n.nodeValue);
          chars += n.nodeValue.length; count += 1;
        }
        return JSON.stringify(S.originals);
      } catch (e) { return "[]"; }
    })();
    """#

    /// Function literal (invoked with the base64 batch) that writes translations into their nodes.
    private static let applyFunction = #"""
    function (b64) {
      try {
        var S = window.__searxlyTx;
        if (!S || !S.nodes || !S.nodes.length) return 0;
        var bytes = Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); });
        var pairs = JSON.parse(new TextDecoder("utf-8").decode(bytes));
        var applied = 0;
        for (var k = 0; k < pairs.length; k++) {
          var i = pairs[k][0], t = pairs[k][1];
          var node = S.nodes[i];
          if (node && typeof t === "string") { try { node.nodeValue = t; applied += 1; } catch (e) {} }
        }
        if (applied > 0) S.on = true;
        return applied;
      } catch (e) { return 0; }
    }
    """#

    private static let restoreScript = #"""
    (function () {
      var S = window.__searxlyTx;
      if (!S || !S.nodes) return false;
      for (var i = 0; i < S.nodes.length; i++) {
        try { S.nodes[i].nodeValue = S.originals[i]; } catch (e) {}
      }
      S.on = false;
      return true;
    })();
    """#
}
