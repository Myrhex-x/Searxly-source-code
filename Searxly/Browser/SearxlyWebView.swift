//
//  SearxlyWebView.swift
//  Searxly
//
//  WKWebView subclass for the browser's page web views: relabels the "Open Link in New Window"
//  context-menu item to "Open Link in New Tab" (our WKUIDelegate routes new windows into Searxly
//  tabs) and enables Safari-like trackpad gestures.
//

import WebKit
import AppKit

final class SearxlyWebView: WKWebView {

    override init(frame frameRect: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        // Safari-like trackpad behaviors (off by default on WKWebView):
        allowsBackForwardNavigationGestures = true   // two-finger swipe ← / → to go back/forward
        allowsMagnification = true                    // pinch-to-zoom the page
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearxlyWebView is created programmatically, never from a coder")
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // 0. Relabel "Open Link in New Window" → "Open Link in New Tab": our WKUIDelegate routes every
        // new-window request (this item, plus target="_blank" and window.open) into a Searxly tab, so
        // the default "Window" wording is misleading.
        if let openInNew = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            openInNew.title = "Open Link in New Tab"
        }
    }


    /// Extracts only human-visible text from the page. Strips the easy hidden-injection vectors:
    /// display:none / visibility:hidden / opacity:0 / aria-hidden / off-screen / 1px / tiny-font, plus
    /// script/style/template/etc. Caps total length. (Defense-in-depth: PageContentGuard + no-tools +
    /// non-actionable output handle anything that still slips through.)
    static let visibleTextExtractionScript = """
    (function() {
      try {
        var MAX = 16000;
        var skip = {SCRIPT:1, STYLE:1, NOSCRIPT:1, TEMPLATE:1, IFRAME:1, SVG:1, CANVAS:1, HEAD:1,
                    META:1, LINK:1, OBJECT:1, EMBED:1, AUDIO:1, VIDEO:1, MAP:1};
        function hidden(el) {
          try {
            if (el.getAttribute && el.getAttribute('aria-hidden') === 'true') return true;
            var cs = window.getComputedStyle(el);
            if (!cs) return false;
            if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return true;
            if (parseFloat(cs.opacity) === 0) return true;
            if (/rgba?\\([^)]*,\\s*0\\s*\\)/.test(cs.color)) return true;   // transparent text (color:transparent)
            var fs = parseFloat(cs.fontSize);
            if (!isNaN(fs) && fs < 4) return true;
            if (cs.textIndent && parseFloat(cs.textIndent) < -500) return true;  // text-indent:-9999px trick
            var r = el.getBoundingClientRect();
            if (r.width <= 1 || r.height <= 1) return true;             // 0/1px sink (either dimension)
            if (r.right < -1500 || r.bottom < -1500) return true;       // pushed off-screen
            return false;
          } catch (e) { return false; }
        }
        if (!document.body) return { title: document.title || '', url: location.href, text: '' };
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function(node) {
            if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
            var p = node.parentElement;
            while (p) {
              if (skip[p.tagName]) return NodeFilter.FILTER_REJECT;
              if (hidden(p)) return NodeFilter.FILTER_REJECT;
              p = p.parentElement;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var out = [], total = 0, n, visited = 0;
        var deadline = Date.now() + 1200;  // best-effort budget so a hostile DOM can't stall extraction
        while ((n = walker.nextNode())) {
          if (((++visited) & 1023) === 0 && Date.now() > deadline) break;
          var t = n.nodeValue.replace(/\\s+/g, ' ').trim();
          if (t) { out.push(t); total += t.length; if (total > MAX) break; }
        }
        return { title: (document.title || '').slice(0, 300), url: location.href, text: out.join(' ').slice(0, MAX) };
      } catch (e) {
        return { title: document.title || '', url: location.href, text: '' };
      }
    })();
    """
}
