//
//  DescribeFormTool.swift
//  Searxly — Agentic Tools
//
//  Structured introspection of the current tab's form fields, so a local AI fills forms accurately
//  (right value into the right field, valid dropdown options) instead of guessing from a flat snapshot.
//  Tags elements with the SAME `data-searxly-ref` pass as page_snapshot (identical selector + order), so
//  the refs it returns are usable directly with click / type / select_option.
//

import Foundation
import WebKit

@MainActor
struct DescribeFormTool: AgenticTool {
    let id = "describe_form"
    let title = "Describe form fields"
    let requiresBrowserControl = true
    let isReadOnly = true
    let summary = "List the fillable form fields on the CURRENT tab as structured data: each field's [ref], label, name, input type, whether it's required, current value, checkbox/radio state, and any dropdown options. Call this before filling a form so you put accurate values into the right fields instead of guessing. Refs match page_snapshot and are reassigned whenever you call either."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    var outputSchema: [String: Any]? {
        [
            "type": "object",
            "properties": [
                "url": ["type": "string"],
                "title": ["type": "string"],
                "count": ["type": "integer"],
                "fields": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "ref": ["type": "integer"],
                            "tag": ["type": "string"],
                            "type": ["type": "string"],
                            "name": ["type": "string"],
                            "label": ["type": "string"],
                            "required": ["type": "boolean"],
                            "value": ["type": "string"],
                            "placeholder": ["type": "string"],
                            "checked": ["type": "boolean"],
                            "options": ["type": "array", "items": ["type": "string"]]
                        ]
                    ]
                ]
            ]
        ]
    }

    // Same tagging pass as BrowserActions.snapshotJS (identical SEL + visibility + order) so refs line up,
    // but it emits rich detail only for actual form controls (skipping submit/button/reset/image inputs).
    private static let js = #"""
    (function(){
      document.querySelectorAll('[data-searxly-ref]').forEach(e => e.removeAttribute('data-searxly-ref'));
      const SEL = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=switch], [role=combobox], [role=textbox], [role=option], [onclick], [tabindex]:not([tabindex="-1"]), summary, [contenteditable="true"]';
      function visible(el){ const r=el.getBoundingClientRect(); if(r.width<=1||r.height<=1) return false; const s=getComputedStyle(el); return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0'; }
      function labelFor(el){
        let n='';
        if(el.labels && el.labels.length) n = el.labels[0].innerText || '';
        if(!n) n = el.getAttribute('aria-label') || '';
        if(!n){ const la = el.closest ? el.closest('label') : null; if(la) n = la.innerText || ''; }
        if(!n) n = el.getAttribute('placeholder') || el.getAttribute('title') || el.name || '';
        return (n||'').replace(/\s+/g,' ').trim().slice(0,120);
      }
      const fields=[]; let i=0;
      for(const el of document.querySelectorAll(SEL)){
        if(i>=200) break;
        if(!visible(el)) continue;
        el.setAttribute('data-searxly-ref', String(i));
        const tag = el.tagName;
        if(tag==='INPUT' || tag==='TEXTAREA' || tag==='SELECT'){
          const ty = (el.getAttribute('type')||el.type||(tag==='TEXTAREA'?'textarea':(tag==='SELECT'?'select':'text'))).toLowerCase();
          if(ty!=='submit' && ty!=='button' && ty!=='reset' && ty!=='image'){
            const f = { ref:i, tag:tag.toLowerCase(), type:ty, name:el.name||'', label:labelFor(el), required:!!el.required };
            const v = String(el.value||'').slice(0,80); if(v) f.value = v;
            const ph = el.getAttribute('placeholder'); if(ph) f.placeholder = ph.slice(0,80);
            if(ty==='checkbox' || ty==='radio') f.checked = !!el.checked;
            if(tag==='SELECT') f.options = Array.from(el.options||[]).slice(0,40).map(o => (o.text||'').replace(/\s+/g,' ').trim().slice(0,60));
            fields.push(f);
          }
        }
        i++;
      }
      return JSON.stringify({ url:location.href, title:document.title, count:fields.length, fields:fields });
    })();
    """#

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard BrowserActions.activeWebView() != nil else { return .failed("No active browser tab.") }
        guard let json = await BrowserActions.eval(Self.js) as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Couldn't read the current page's forms.")
        }
        let fields = (obj["fields"] as? [[String: Any]]) ?? []
        let title = (obj["title"] as? String) ?? ""
        let url = (obj["url"] as? String) ?? ""
        guard !fields.isEmpty else {
            return .ok("No fillable form fields found on \(title.isEmpty ? url : "\"\(title)\""). The page may have no form, or it may still be loading — snapshot again in a moment.")
        }

        var lines = ["Form fields on \"\(title)\" — \(url):"]
        for f in fields {
            let ref = f["ref"] as? Int ?? -1
            let type = (f["type"] as? String) ?? "text"
            var line = "[\(ref)] \(type)"
            if let label = f["label"] as? String, !label.isEmpty { line += " — \(label)" }
            if let name = f["name"] as? String, !name.isEmpty { line += " (name=\(name))" }
            if (f["required"] as? Bool) == true { line += " *required" }
            if let value = f["value"] as? String, !value.isEmpty { line += " value=\"\(value)\"" }
            if let checked = f["checked"] as? Bool { line += checked ? " [checked]" : " [unchecked]" }
            if let options = f["options"] as? [String], !options.isEmpty {
                line += " — options: " + options.prefix(12).joined(separator: ", ")
            }
            lines.append(line)
        }
        return .okStructured(text: lines.joined(separator: "\n"), structuredJSON: data)
    }
}
