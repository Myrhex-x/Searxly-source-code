//
//  BrowserActionsExtraTools.swift
//  Searxly — Agentic Tools
//
//  Speed + completeness tools for the browser-control tier:
//   • fill_form — set MANY fields in ONE in-page pass (a 30-field form = 1 call, not 30), so form
//     filling doesn't burn the rate-limit budget or crawl one field at a time.
//   • find_text — jump to text on a long page.
//   • go_forward — the history-forward companion to go_back.
//

import Foundation
import WebKit

// MARK: - fill_form (batch fill, the big speed win)

@MainActor
struct FillFormTool: AgenticTool {
    let id = "fill_form"
    let title = "Fill a form"
    let requiresBrowserControl = true
    let summary = "Fill MANY form fields in ONE call — far faster than typing them one at a time. Pass 'fields' as a list of {ref, value} from page_snapshot or describe_form. For checkboxes/radios use \"true\"/\"false\"; for dropdowns use the option's value or visible text. Set submit=true to submit afterwards (this pauses for the user's approval). Password and hidden fields are refused and reported as skipped."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "fields": [
                "type": "array",
                "description": "The fields to fill, in one pass.",
                "items": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "integer", "description": "The field's [ref] from page_snapshot / describe_form."],
                        "value": ["type": "string", "description": "The value to set. For checkbox/radio use \"true\"/\"false\"; for a <select> use the option value or its visible text."]
                    ],
                    "required": ["ref", "value"]
                ]
            ],
            "submit": ["type": "boolean", "description": "Submit the form after filling. Pauses for the user's approval. Default false."]
        ],
        "required": ["fields"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let rawFields = arguments["fields"] as? [[String: Any]], !rawFields.isEmpty else {
            return .failed("Missing 'fields' — a list of {ref, value}.")
        }
        // Normalize to [{ref:Int, value:String}] so the injected JSON is well-typed and safe.
        var norm: [[String: Any]] = []
        for f in rawFields {
            guard let ref = BrowserActions.intArg(f["ref"]) else { continue }
            let value: String
            if let s = f["value"] as? String { value = s }
            else if let b = f["value"] as? Bool { value = b ? "true" : "false" }
            else if let n = f["value"] as? NSNumber { value = n.stringValue }
            else { value = "" }
            norm.append(["ref": ref, "value": value])
        }
        guard !norm.isEmpty,
              let fieldsData = try? JSONSerialization.data(withJSONObject: norm),
              let fieldsJSON = String(data: fieldsData, encoding: .utf8) else {
            return .failed("No valid fields — each needs an integer 'ref'.")
        }

        // One pass over every field. Values are a JSON array (JSONSerialization escapes them), set via
        // element.value — never innerHTML — so there's no injection surface.
        let fillJS = """
        (function(){
          var fields = \(fieldsJSON);
          var filled=[], skipped=[], missing=[];
          for (var i=0;i<fields.length;i++){
            var f=fields[i];
            var e=document.querySelector('[data-searxly-ref="'+f.ref+'"]');
            if(!e){ missing.push(f.ref); continue; }
            var t=((e.getAttribute('type')||e.type||'')+'').toLowerCase();
            if(e.tagName==='INPUT'&&(t==='password'||t==='hidden')){ skipped.push(f.ref); continue; }
            try {
              e.focus();
              if(e.tagName==='SELECT'){
                var want=String(f.value);
                var opt=Array.prototype.slice.call(e.options||[]).filter(function(o){return o.value===want||o.text===want;})[0];
                e.value = opt ? opt.value : want;
              } else if(t==='checkbox'||t==='radio'){
                var v=String(f.value).toLowerCase();
                e.checked = (v==='true'||v==='1'||v==='on'||v==='yes'||v==='checked');
              } else if(e.isContentEditable){
                e.textContent = String(f.value);
              } else {
                e.value = String(f.value);
              }
              e.dispatchEvent(new Event('input',{bubbles:true}));
              e.dispatchEvent(new Event('change',{bubbles:true}));
              filled.push(f.ref);
            } catch(err){ missing.push(f.ref); }
          }
          return JSON.stringify({filled:filled, skipped:skipped, missing:missing});
        })();
        """
        guard let raw = await BrowserActions.eval(fillJS) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("No active browser tab, or the page couldn't be filled.")
        }
        let filled = (obj["filled"] as? [Int]) ?? []
        let skipped = (obj["skipped"] as? [Int]) ?? []
        let missing = (obj["missing"] as? [Int]) ?? []

        var parts = ["Filled \(filled.count) field\(filled.count == 1 ? "" : "s")"]
        if !skipped.isEmpty {
            parts.append("skipped \(skipped.count) password/hidden field\(skipped.count == 1 ? "" : "s") (\(skipped.map(String.init).joined(separator: ", ")))")
        }
        if !missing.isEmpty {
            parts.append("\(missing.count) ref\(missing.count == 1 ? "" : "s") not found — re-run page_snapshot (\(missing.map(String.init).joined(separator: ", ")))")
        }
        var message = parts.joined(separator: "; ") + "."

        // Optional submit — same human-in-the-loop gate as type/click.
        let submit = (arguments["submit"] as? Bool) ?? false
        if submit && !filled.isEmpty {
            let host = BrowserActions.currentURL().flatMap { URL(string: $0)?.host } ?? "this page"
            // confirm() returns true immediately when the confirm setting is off, so this is a no-op gate then.
            let approved = await AgenticApproval.shared.confirm(title: "Submit a form?", detail: "The AI wants to submit a form on \(host).")
            if approved {
                let before = BrowserActions.currentURL()
                let submitJS = """
                (function(){
                  var refs = \(filled.map(String.init));
                  for (var i=refs.length-1;i>=0;i--){
                    var e=document.querySelector('[data-searxly-ref="'+refs[i]+'"]');
                    if(e && e.form){ if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();} return 'submitted'; }
                  }
                  return 'no_form';
                })();
                """
                if (await BrowserActions.eval(submitJS) as? String) == "submitted" {
                    message += " Submitted the form. \(await BrowserActions.describeNavigation(from: before))"
                } else {
                    message += " Couldn't find a form to submit (the fields are filled)."
                }
            } else {
                message += " Submit was declined; the fields are filled but the form was not submitted."
            }
        }
        return .ok(message)
    }
}

// MARK: - find_text

@MainActor
struct FindTextTool: AgenticTool {
    let id = "find_text"
    let title = "Find text on page"
    let requiresBrowserControl = true
    let isReadOnly = true
    let summary = "Find text on the CURRENT page and scroll to the first match. Returns whether it was found plus a little surrounding context. Use on long pages to jump to the relevant part before reading or acting."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "Text to find on the page."]],
        "required": ["text"]
    ]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let text = arguments["text"] as? String, !text.isEmpty else { return .failed("Missing 'text'.") }
        let q = BrowserActions.jsLiteral(text)
        let js = """
        (function(){
          try {
            var sel = window.getSelection(); if(sel) sel.removeAllRanges();
            var found = window.find ? window.find(\(q), false, false, true, false, true, false) : false;
            if(!found){
              var body = document.body ? (document.body.innerText||'') : '';
              var idx = body.indexOf(\(q));
              if(idx < 0) return JSON.stringify({found:false});
              return JSON.stringify({found:true, context: body.slice(Math.max(0, idx-40), idx+120)});
            }
            var s = window.getSelection(); var ctx='';
            if(s && s.anchorNode){
              ctx = (s.anchorNode.textContent||'').slice(0,200);
              if(s.anchorNode.parentElement){ s.anchorNode.parentElement.scrollIntoView({block:'center'}); }
            }
            return JSON.stringify({found:true, context:ctx});
          } catch(e){ return JSON.stringify({found:false}); }
        })();
        """
        guard let raw = await BrowserActions.eval(js) as? String,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("No active browser tab, or the page couldn't be searched.")
        }
        guard (obj["found"] as? Bool) == true else {
            return .failed("\"\(text)\" was not found on this page.")
        }
        let ctx = ((obj["context"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return .ok(ctx.isEmpty ? "Found \"\(text)\" and scrolled to it."
                              : "Found \"\(text)\" and scrolled to it. Context: …\(ctx)…")
    }
}

// MARK: - go_forward

@MainActor
struct GoForwardTool: AgenticTool {
    let id = "go_forward"
    let title = "Go forward"
    let requiresBrowserControl = true
    let summary = "Go forward one page in the current tab's history (the companion to go_back)."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(_ arguments: [String: Any]) async -> AgenticToolOutcome {
        guard let browserState = AgenticServerManager.shared.browserState else { return .failed("Searxly not ready.") }
        guard browserState.activeWebView.canGoForward else { return .failed("No page to go forward to.") }
        let before = BrowserActions.currentURL()
        browserState.goForward()
        let nav = await BrowserActions.describeNavigation(from: before)
        return .ok("Went forward. \(nav)")
    }
}
