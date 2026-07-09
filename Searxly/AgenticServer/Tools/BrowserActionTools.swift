//
//  BrowserActionTools.swift
//  Searxly — Agentic Tools
//
//  The "browser control" tier: lets a user's local AI act on their REAL active tab — snapshot the page,
//  click, type, navigate, screenshot — modelled on Playwright MCP's accessibility-snapshot + ref pattern
//  (no vision needed, so it works with any local model). Implemented natively via WKWebView JS injection
//  on the user's own session; nothing headless, nothing leaves the machine.
//
//  Every tool here sets `requiresBrowserControl = true`, so it's hidden + refused until the user turns on
//  the "Browser control" opt-in in Settings (these change or expose the live browsing session).
//

import Foundation
import WebKit
import AppKit

// MARK: - Shared helpers

@MainActor
enum BrowserActions {
    static func activeWebView() -> WKWebView? {
        AgenticServerManager.shared.browserState?.activeWebView
    }

    /// Evaluate JS in the active tab; nil on error / no tab.
    static func eval(_ js: String) async -> Any? {
        guard let wv = activeWebView() else { return nil }
        return try? await wv.evaluateJavaScript(js)
    }

    /// A quoted, escaped JS/JSON string literal for safe interpolation into injected JS.
    static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
              let lit = String(data: data, encoding: .utf8) else { return "\"\"" }
        return lit
    }

    static func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func boolResult(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    static func currentURL() -> String? { activeWebView()?.url?.absoluteString }

    static func pageTitle() async -> String { (await eval("document.title") as? String) ?? "" }

    /// After an action that may navigate, wait briefly for the URL to change, then describe where we
    /// landed — so the model (and the user) always know the result of a click/navigate.
    static func describeNavigation(from previous: String?) async -> String {
        for _ in 0..<10 {   // up to ~2s
            try? await Task.sleep(nanoseconds: 200_000_000)
            if currentURL() != previous { break }
        }
        let url = currentURL() ?? "unknown"
        let title = await pageTitle()
        if url == previous {
            return "The page did not navigate (the action likely changed something in place)."
        }
        return "Now on \"\(title)\" — \(url)"
    }

    /// Tags visible interactive elements with a stable `data-searxly-ref` and returns a compact snapshot.
    static let snapshotJS = #"""
    (function() {
      document.querySelectorAll('[data-searxly-ref]').forEach(e => e.removeAttribute('data-searxly-ref'));
      const SEL = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch], [role=combobox], [role=textbox], [role=option], [onclick], [tabindex]:not([tabindex="-1"]), summary, [contenteditable="true"]';
      function visible(el) {
        const r = el.getBoundingClientRect();
        if (r.width <= 1 || r.height <= 1) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      }
      function label(el) {
        let n = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || '';
        if (!n) {
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') n = el.name || el.getAttribute('type') || '';
          else n = (el.innerText || el.textContent || '');
        }
        return n.replace(/\s+/g, ' ').trim().slice(0, 120);
      }
      const out = [];
      let i = 0;
      for (const el of document.querySelectorAll(SEL)) {
        if (i >= 200) break;
        if (!visible(el)) continue;
        el.setAttribute('data-searxly-ref', String(i));
        const item = { ref: i, role: (el.getAttribute('role') || el.tagName.toLowerCase()), name: label(el) };
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { item.value = String(el.value || '').slice(0, 80); item.type = el.type || 'text'; }
        const lnk = (el.tagName === 'A' && el.href) ? el : (el.closest ? el.closest('a[href]') : null);
        if (lnk && lnk.href) { try { item.href = new URL(lnk.href).host; } catch (e) {} }
        out.push(item);
        i++;
      }
      return JSON.stringify({ url: location.href, title: document.title, count: out.length, elements: out });
    })();
    """#

    /// Render the snapshot JSON as a compact, model-friendly element list.
    static func formatSnapshot(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return json }
        let title = (obj["title"] as? String) ?? ""
        let url = (obj["url"] as? String) ?? ""
        let elements = (obj["elements"] as? [[String: Any]]) ?? []
        var lines = ["Page: \(title) — \(url)", "Interactive elements (use the [ref] with click / type):"]
        for e in elements {
            let ref = e["ref"] as? Int ?? -1
            let role = e["role"] as? String ?? "?"
            let name = e["name"] as? String ?? ""
            var line = "[\(ref)] \(role)"
            if !name.isEmpty { line += " \"\(name)\"" }
            if let type = e["type"] as? String { line += " (type=\(type))" }
            if let value = e["value"] as? String, !value.isEmpty { line += " value=\"\(value)\"" }
            if let host = e["href"] as? String, !host.isEmpty { line += " → \(host)" }
            lines.append(line)
        }
        if elements.isEmpty { lines.append("(no interactive elements found — the page may still be loading)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Snapshot

@MainActor
struct PageSnapshotTool: AgenticTool {
    let id = "page_snapshot"
    let requiresBrowserControl = true
    let summary = "Capture a structured snapshot of the CURRENT browser tab: its URL/title and the visible interactive elements (links, buttons, inputs), each tagged with a [ref] id. Call this first, then use the refs with click/type. Re-snapshot after the page changes — refs are reassigned each time."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard BrowserActions.activeWebView() != nil else { return .failed("No active browser tab.") }
        guard let json = await BrowserActions.eval(BrowserActions.snapshotJS) as? String else {
            return .failed("Couldn't read the current page.")
        }
        return .ok(BrowserActions.formatSnapshot(json))
    }
}

// MARK: - Click

@MainActor
struct ClickTool: AgenticTool {
    let id = "click"
    let requiresBrowserControl = true
    let summary = "Click an element in the current tab by its [ref] from page_snapshot."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["ref": ["type": "integer", "description": "The element ref from page_snapshot."]],
        "required": ["ref"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let ref = BrowserActions.intArg(arguments["ref"]) else { return .failed("Missing integer 'ref'.") }
        let before = BrowserActions.currentURL()
        // Dispatch a full, realistic event sequence (not a bare .click()) so JS-driven controls react,
        // and capture the element's label + link target so we can report exactly what was clicked.
        let js = """
        (function(){
          var e=document.querySelector('[data-searxly-ref="\(ref)"]');
          if(!e) return JSON.stringify({ok:false});
          e.scrollIntoView({block:'center'});
          var lnk = (e.tagName==='A' && e.href) ? e : (e.closest ? e.closest('a[href]') : null);
          var href = lnk ? lnk.href : '';
          var label = (e.innerText||e.textContent||e.getAttribute('aria-label')||'').replace(/\\s+/g,' ').trim().slice(0,80);
          try { ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){ e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window})); }); }
          catch(err) { try { e.click(); } catch(e2) {} }
          return JSON.stringify({ok:true, href:href, label:label});
        })();
        """
        guard let raw = await BrowserActions.eval(js) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true else {
            return .failed("No element with ref \(ref) — run page_snapshot again (refs reset on every snapshot).")
        }
        let label = (obj["label"] as? String) ?? ""
        let what = label.isEmpty ? "[\(ref)]" : "[\(ref)] \"\(label)\""
        let nav = await BrowserActions.describeNavigation(from: before)
        return .ok("Clicked \(what). \(nav)")
    }
}

// MARK: - Type

@MainActor
struct TypeTool: AgenticTool {
    let id = "type"
    let requiresBrowserControl = true
    let summary = "Type text into an input or textarea in the current tab by its [ref]. Set submit=true to press Enter afterwards (e.g. to run a search)."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "ref": ["type": "integer", "description": "The input's ref from page_snapshot."],
            "text": ["type": "string", "description": "The text to type."],
            "submit": ["type": "boolean", "description": "Press Enter / submit the form after typing. Default false."]
        ],
        "required": ["ref", "text"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let ref = BrowserActions.intArg(arguments["ref"]) else { return .failed("Missing integer 'ref'.") }
        guard let text = arguments["text"] as? String else { return .failed("Missing 'text'.") }
        let submit = (arguments["submit"] as? Bool) ?? false
        let value = BrowserActions.jsLiteral(text)
        let submitJS = submit ? """
        e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
        e.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
        if(e.form){ if(e.form.requestSubmit){ e.form.requestSubmit(); } else { e.form.submit(); } }
        """ : ""
        let js = """
        (function(){var e=document.querySelector('[data-searxly-ref="\(ref)"]');if(!e)return 'not_found';e.focus();if(e.isContentEditable){e.textContent=\(value);}else{e.value=\(value);}e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));\(submitJS)return 'ok';})();
        """
        let result = await BrowserActions.eval(js) as? String
        return result == "ok" ? .ok("Typed into [\(ref)]\(submit ? " and submitted." : ".")") : .failed("No element with ref \(ref) — run page_snapshot again.")
    }
}

// MARK: - Select option

@MainActor
struct SelectOptionTool: AgenticTool {
    let id = "select_option"
    let requiresBrowserControl = true
    let summary = "Choose a value in a <select> dropdown in the current tab by its [ref]."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "ref": ["type": "integer", "description": "The <select>'s ref from page_snapshot."],
            "value": ["type": "string", "description": "The option value or visible label to select."]
        ],
        "required": ["ref", "value"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let ref = BrowserActions.intArg(arguments["ref"]) else { return .failed("Missing integer 'ref'.") }
        guard let value = arguments["value"] as? String else { return .failed("Missing 'value'.") }
        let v = BrowserActions.jsLiteral(value)
        let js = """
        (function(){var e=document.querySelector('[data-searxly-ref="\(ref)"]');if(!e)return 'not_found';var want=\(v);var opt=Array.from(e.options||[]).find(function(o){return o.value===want||o.text===want;});if(opt){e.value=opt.value;}else{e.value=want;}e.dispatchEvent(new Event('change',{bubbles:true}));return 'ok';})();
        """
        let result = await BrowserActions.eval(js) as? String
        return result == "ok" ? .ok("Selected \"\(value)\" in [\(ref)].") : .failed("No element with ref \(ref) — run page_snapshot again.")
    }
}

// MARK: - Press key

@MainActor
struct PressKeyTool: AgenticTool {
    let id = "press_key"
    let requiresBrowserControl = true
    let summary = "Press a keyboard key in the current tab (e.g. 'Enter', 'Escape', 'ArrowDown', 'Tab'). Sent to the focused element."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["key": ["type": "string", "description": "Key name, e.g. Enter, Escape, ArrowDown, Tab."]],
        "required": ["key"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let key = arguments["key"] as? String, !key.isEmpty else { return .failed("Missing 'key'.") }
        let k = BrowserActions.jsLiteral(key)
        let js = """
        (function(){var t=document.activeElement||document.body;var k=\(k);t.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true}));t.dispatchEvent(new KeyboardEvent('keyup',{key:k,bubbles:true}));return 'ok';})();
        """
        _ = await BrowserActions.eval(js)
        return .ok("Pressed \(key).")
    }
}

// MARK: - Scroll

@MainActor
struct ScrollTool: AgenticTool {
    let id = "scroll"
    let requiresBrowserControl = true
    let summary = "Scroll the current tab. Pass a direction (down/up/top/bottom), or a [ref] to scroll that element into view."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "direction": ["type": "string", "enum": ["down", "up", "top", "bottom"], "description": "Scroll direction. Default down."],
            "ref": ["type": "integer", "description": "Optional: scroll this element (from page_snapshot) into view instead."]
        ]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        if let ref = BrowserActions.intArg(arguments["ref"]) {
            let js = """
            (function(){var e=document.querySelector('[data-searxly-ref="\(ref)"]');if(!e)return 'not_found';e.scrollIntoView({block:'center'});return 'ok';})();
            """
            let r = await BrowserActions.eval(js) as? String
            return r == "ok" ? .ok("Scrolled [\(ref)] into view.") : .failed("No element with ref \(ref).")
        }
        let direction = (arguments["direction"] as? String)?.lowercased() ?? "down"
        let js: String
        switch direction {
        case "up":     js = "window.scrollBy(0, -Math.round(window.innerHeight*0.85)); 'ok';"
        case "top":    js = "window.scrollTo(0, 0); 'ok';"
        case "bottom": js = "window.scrollTo(0, document.body.scrollHeight); 'ok';"
        default:       js = "window.scrollBy(0, Math.round(window.innerHeight*0.85)); 'ok';"
        }
        _ = await BrowserActions.eval(js)
        return .ok("Scrolled \(direction).")
    }
}

// MARK: - Navigate / back / reload (drive the active tab via BrowserState)

@MainActor
struct NavigateTool: AgenticTool {
    let id = "navigate"
    let requiresBrowserControl = true
    let summary = "Navigate the current tab to a URL. Accepts a full URL or a bare domain (https is assumed)."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["url": ["type": "string", "description": "The URL (or domain) to open in the current tab."]],
        "required": ["url"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard var raw = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failed("Missing 'url'.")
        }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let browserState = AgenticServerManager.shared.browserState else {
            return .failed("Invalid URL or Searxly not ready.")
        }
        browserState.showingWebContent = true
        let before = BrowserActions.currentURL()
        browserState.loadInWebView(url)
        let nav = await BrowserActions.describeNavigation(from: before)
        return .ok("Opened \(url.absoluteString). \(nav)")
    }
}

@MainActor
struct GoBackTool: AgenticTool {
    let id = "go_back"
    let requiresBrowserControl = true
    let summary = "Go back one page in the current tab's history."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else { return .failed("Searxly not ready.") }
        guard browserState.activeWebView.canGoBack else { return .failed("No page to go back to.") }
        let before = BrowserActions.currentURL()
        browserState.goBack()
        let nav = await BrowserActions.describeNavigation(from: before)
        return .ok("Went back. \(nav)")
    }
}

@MainActor
struct ReloadTool: AgenticTool {
    let id = "reload"
    let requiresBrowserControl = true
    let summary = "Reload the current tab."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let wv = BrowserActions.activeWebView() else { return .failed("No active browser tab.") }
        wv.reload()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let title = await BrowserActions.pageTitle()
        return .ok(title.isEmpty ? "Reloaded." : "Reloaded \"\(title)\".")
    }
}

// MARK: - Wait for text

@MainActor
struct WaitForTool: AgenticTool {
    let id = "wait_for"
    let requiresBrowserControl = true
    let summary = "Wait until some text appears on the current page (up to ~10s). Useful after a click/navigation that loads content."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "Text to wait for on the page."]],
        "required": ["text"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let text = arguments["text"] as? String, !text.isEmpty else { return .failed("Missing 'text'.") }
        let needle = BrowserActions.jsLiteral(text)
        let js = "(function(){return !!(document.body && document.body.innerText && document.body.innerText.indexOf(\(needle)) >= 0);})();"
        for _ in 0..<33 {   // ~10s at 0.3s intervals
            if BrowserActions.boolResult(await BrowserActions.eval(js)) {
                return .ok("Found \"\(text)\" on the page.")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return .failed("Timed out waiting for \"\(text)\".")
    }
}

// MARK: - Screenshot

@MainActor
struct ScreenshotTool: AgenticTool {
    let id = "screenshot"
    let requiresBrowserControl = true
    let summary = "Capture a PNG screenshot of the current tab's visible area. Use only if you need to see the page visually — page_snapshot is usually better and cheaper."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let wv = BrowserActions.activeWebView() else { return .failed("No active browser tab.") }
        let config = WKSnapshotConfiguration()
        return await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: config) { image, _ in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: .failed("Couldn't capture a screenshot."))
                    return
                }
                continuation.resume(returning: .image(base64: png.base64EncodedString(), mimeType: "image/png"))
            }
        }
    }
}
