//
//  WebExtensionSpike.swift
//  Searxly
//
//  Lane A — Phase 0 spike. Proves the real `WKWebExtension` engine (macOS 15.4+) can:
//    1. parse a manifest into a WKWebExtension,
//    2. load it into a WKWebExtensionController via a WKWebExtensionContext (with host access granted),
//    3. attach to a WKWebView through minimal WKWebExtensionTab / WKWebExtensionWindow adapters,
//    4. actually run a content script against a loaded page.
//
//  Deliberately ISOLATED and self-contained: it writes a tiny throwaway MV3 extension to a temp dir and
//  uses its own offscreen webview + adapter objects. It does NOT touch BrowserTab, WebViewFactory, or the
//  Lane B userscript runtime — that integration is later phases. Dev-Mode only; gated to macOS 15.4.
//
//  This is the de-risking step for the curated WebExtension gallery: if the API shapes here line up and a
//  content script runs, the rest of Lane A is "productionizing" this path.
//

import Foundation
import WebKit
import os

@available(macOS 15.4, *)
@MainActor
final class WebExtensionSpike {

    struct Report {
        var ok: Bool
        var lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    /// Runs the full spike and returns a human-readable, step-by-step report.
    func run() async -> Report {
        var lines: [String] = []
        func step(_ ok: Bool, _ msg: String) { lines.append((ok ? "✓ " : "✗ ") + msg) }

        // 1. Write a minimal MV3 extension to a temp directory.
        let dir: URL
        do {
            dir = try Self.writeTestExtension()
            step(true, "Wrote test extension to \(dir.path)")
        } catch {
            step(false, "Failed to write test extension: \(error.localizedDescription)")
            return Report(ok: false, lines: lines)
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2. Parse the manifest into a WKWebExtension.
        let ext: WKWebExtension
        do {
            ext = try await WKWebExtension(resourceBaseURL: dir)
            step(true, "Parsed extension — manifest v\(Int(ext.manifestVersion))")
        } catch {
            step(false, "WKWebExtension parse failed: \(error.localizedDescription)")
            return Report(ok: false, lines: lines)
        }

        // 3. Controller + context, with all-hosts access granted so the content script may run.
        let controller = WKWebExtensionController()
        let context = WKWebExtensionContext(for: ext)
        context.grantedPermissionMatchPatterns = [
            WKWebExtension.MatchPattern.allHostsAndSchemes(): Date.distantFuture
        ]
        do {
            try controller.load(context)
            step(true, "Loaded context into controller (host access granted)")
        } catch {
            step(false, "controller.load failed: \(error.localizedDescription)")
            return Report(ok: false, lines: lines)
        }

        // 4. Offscreen webview wired to the controller, plus minimal tab/window adapters.
        let config = WKWebViewConfiguration()
        config.webExtensionController = controller
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)

        let tab = SpikeTab(webView: webView)
        let window = SpikeWindow(tab: tab)
        tab.owningWindow = window

        controller.didOpenWindow(window)
        controller.didOpenTab(tab)
        step(true, "WebView created; tab + window registered with controller")

        // 5. Load a page (no network: real https origin via loadHTMLString baseURL) and check the content
        //    script ran. The script prepends "SPIKE-OK " to document.title — observable cross-world via DOM.
        let html = "<!doctype html><html><head><title>spike</title></head><body>hello</body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))

        // Give the page time to finish + content script to inject at document_idle.
        try? await Task.sleep(nanoseconds: 1_800_000_000)

        do {
            let title = (try await webView.evaluateJavaScript("document.title")) as? String ?? ""
            if title.hasPrefix("SPIKE-OK") {
                step(true, "Content script executed — document.title = \"\(title)\"")
            } else {
                step(false, "Content script not detected — document.title = \"\(title)\"")
                lines.append("   (engine loaded fine; content-script injection is the part to investigate)")
            }
        } catch {
            step(false, "Could not read back document.title: \(error.localizedDescription)")
        }

        // Tidy up.
        try? controller.unload(context)

        let ok = !lines.contains { $0.hasPrefix("✗") }
        lines.append(ok ? "\nSPIKE PASSED — Lane A engine is viable." : "\nSPIKE INCOMPLETE — see failures above.")
        Log.web.info("[WebExtensionSpike] \(ok ? "passed" : "incomplete", privacy: .public)")
        return Report(ok: ok, lines: lines)
    }

    // MARK: - Throwaway test extension

    static func writeTestExtension() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("searxly-webext-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Searxly Spike",
          "version": "1.0",
          "description": "Phase 0 spike — verifies the WebExtension engine end-to-end.",
          "content_scripts": [
            {
              "matches": ["<all_urls>"],
              "js": ["content.js"],
              "run_at": "document_idle"
            }
          ]
        }
        """
        let content = """
        (function () {
          try {
            document.title = "SPIKE-OK " + document.title;
            console.log("[Searxly spike] content script ran on " + location.href);
          } catch (e) {}
        })();
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try content.write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        return dir
    }
}

// MARK: - Minimal protocol adapters (all WKWebExtension protocol methods are optional)

/// Minimal tab adapter. Only implements what the engine needs to inject into and identify the tab.
@available(macOS 15.4, *)
@MainActor
private final class SpikeTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var owningWindow: SpikeWindow?

    init(webView: WKWebView) { self.webView = webView }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owningWindow }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
}

/// Minimal single-tab window adapter.
@available(macOS 15.4, *)
@MainActor
private final class SpikeWindow: NSObject, WKWebExtensionWindow {
    let tab: SpikeTab

    init(tab: SpikeTab) { self.tab = tab }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}
