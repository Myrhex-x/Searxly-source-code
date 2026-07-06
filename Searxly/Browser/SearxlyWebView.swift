//
//  SearxlyWebView.swift
//  Searxly
//
//  WKWebView subclass that adds an "Ask Searxly AI" submenu to the page right-click menu when text
//  is selected. Choosing an item fetches the live selection and posts `.searxlyAskAISelection`, which
//  BrowserState turns into an opened Searxly AI chat seeded with that text (ask / explain / summarize).
//
//  This is the first "Searxly AI everywhere in the browser" surface (review section C).
//

import WebKit
import AppKit

/// What an "Ask Searxly AI" selection action should do once the chat opens.
struct AIChatSeed: Equatable {
    enum Action: String, Equatable { case ask, explain, summarize, summarizePage }
    let selection: String
    let action: Action
    /// Set when handed off from the quick-answer popup ("Talk to Searxly"): the answer already shown,
    /// injected as the assistant's reply so the chat continues with context.
    var priorAnswer: String? = nil
}

extension Notification.Name {
    /// Posted by `SearxlyWebView` when the user picks an "Ask Searxly AI" context-menu item.
    /// userInfo: ["text": <selection>, "action": <AIChatSeed.Action.rawValue>]
    /// `nonisolated` so it can be referenced from nonisolated contexts (e.g. BrowserState observers)
    /// under the module's default-MainActor isolation.
    nonisolated static let searxlyAskAISelection = Notification.Name("Searxly.askAISelection")
}

final class SearxlyWebView: WKWebView {

    /// WebKit context-menu item identifiers that only appear when text is selected — used to detect a
    /// selection synchronously so we only show "Ask Searxly AI" when it's relevant.
    private static let textSelectionMenuIDs: Set<String> = [
        "WKMenuItemIdentifierLookUp",
        "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierSearchWeb"
    ]

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

        // 1. Text-selection actions (top of menu) when something is selected.
        let hasSelection = menu.items.contains { item in
            guard let id = item.identifier?.rawValue else { return false }
            return Self.textSelectionMenuIDs.contains(id)
        }
        if hasSelection, AIFeatures.programEnabled {
            let ask = NSMenuItem(title: "Ask Searxly AI", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(makeAskItem(title: "Ask about selection", action: .ask))
            submenu.addItem(makeAskItem(title: "Explain selection", action: .explain))
            submenu.addItem(makeAskItem(title: "Summarize selection", action: .summarize))
            ask.submenu = submenu

            let insertAt = min(1, menu.items.count)
            menu.insertItem(NSMenuItem.separator(), at: insertAt)
            menu.insertItem(ask, at: insertAt)
        }

        // 2. Whole-page summary (bottom of menu) for real web pages only.
        if AIFeatures.programEnabled,
           let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let item = NSMenuItem(title: "Summarize this page with Searxly AI",
                                  action: #selector(summarizePageWithSearxly(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item)
        }
    }

    private func makeAskItem(title: String, action: AIChatSeed.Action) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(askSearxlyAI(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        return item
    }

    @objc private func askSearxlyAI(_ sender: NSMenuItem) {
        let actionRaw = (sender.representedObject as? String) ?? AIChatSeed.Action.ask.rawValue
        // The selection is still live (the menu was opened over it); fetch it now.
        evaluateJavaScript("window.getSelection().toString()") { result, _ in
            let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            NotificationCenter.default.post(
                name: .searxlyAskAISelection,
                object: nil,
                userInfo: ["text": text, "action": actionRaw]
            )
        }
    }

    @objc private func summarizePageWithSearxly(_ sender: NSMenuItem) {
        // Extract VISIBLE text only — the first line of defense against hidden-text injection.
        evaluateJavaScript(Self.visibleTextExtractionScript) { result, _ in
            let dict = result as? [String: Any]
            let text = (dict?["text"] as? String) ?? ""
            let title = (dict?["title"] as? String) ?? ""
            let urlStr = (dict?["url"] as? String) ?? ""
            NotificationCenter.default.post(
                name: .searxlyAskAISelection,
                object: nil,
                userInfo: [
                    "text": text,
                    "action": AIChatSeed.Action.summarizePage.rawValue,
                    "title": title,
                    "url": urlStr
                ]
            )
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
