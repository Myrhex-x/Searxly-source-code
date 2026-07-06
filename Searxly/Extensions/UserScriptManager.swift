//
//  UserScriptManager.swift
//  Searxly
//
//  Lane B runtime. The @MainActor singleton that owns the userscript registry, persistence, and the
//  single injection point. Mirrors AdBlockManager's shape on purpose: one manager, one application point
//  (WebViewFactory), minimal blast radius.
//
//  Security posture (see EXTENSION_IMPLEMENTATION_NOTES.md):
//   - Scripts run ONLY on `.standard` tabs — never Private or Onion/Tor (a script there could
//     deanonymize the session). Same gate the wallet provider uses.
//   - Each script runs in an ISOLATED WKContentWorld, so it cannot see the page's JS globals and
//     cannot reach Searxly's native message handlers (those live in the `.page` world).
//   - Each body is wrapped so bare `fetch` / `XMLHttpRequest` / `WebSocket` / `webkit` / `chrome`
//     resolve to throwing stubs (runtime shadowing), and is rejected by UserScriptValidator before it
//     can ever be enabled (static scan for eval / Function / window.fetch / .constructor / …).
//   - Only scripts that are both enabled AND currently pass validation are injected.
//

import Foundation
import WebKit
import os

enum UserScriptNotifications {
    /// Posted (main thread) when the script list or global toggle changes. Existing webviews pick up
    /// changes on their next navigation/reload; new tabs get them immediately.
    nonisolated static let didChange = Notification.Name("Searxly.UserScriptsDidChange")
}

@MainActor
final class UserScriptManager {
    static let shared = UserScriptManager()

    private static let enabledKey = "userScriptsEnabled"
    private static let contentWorldName = "SearxlyUserScripts"

    /// Global master toggle (independent of any individual script's `isEnabled`).
    private(set) var isEnabled: Bool

    private(set) var scripts: [UserScript] = []
    private var hasLoaded = false

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
        isEnabled = stored ?? true
    }

    // MARK: - Lifecycle

    /// Called once at launch (SearxlyApp.init), mirroring AdBlockManager.prepare(). Warms the registry so
    /// the first webview can inject synchronously. Inert while the Extensions program is off.
    func prepare() {
        guard ExtensionFeatures.programEnabled else { return }
        ensureLoaded()
    }

    private func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        scripts = UserScriptStore.load()
    }

    /// Scripts that are enabled AND currently pass validation. Invalid scripts are never injected even if
    /// their stored `isEnabled` flag is true — validation is re-checked at injection time.
    private var injectableScripts: [UserScript] {
        scripts.filter { $0.isEnabled && UserScriptValidator.validate($0).isValid }
    }

    // MARK: - Injection (the single application point)

    /// Applies enabled userscripts to a webview configuration. Call from WebViewFactory.makeWebView, right
    /// beside AdBlockManager.shared.apply(to:). No-op unless the master toggle is on AND the tab is
    /// `.standard` (never Private/Onion).
    func apply(to configuration: WKWebViewConfiguration, mode: TabPrivacyMode) {
        guard ExtensionFeatures.programEnabled else { return }
        guard isEnabled, mode == .standard else { return }
        ensureLoaded()

        let toInject = injectableScripts
        guard !toInject.isEmpty else { return }

        let world = WKContentWorld.world(name: Self.contentWorldName)
        let ucc = configuration.userContentController

        // Prelude (match-pattern helper) once per configuration, before any script body.
        ucc.addUserScript(WKUserScript(
            source: Self.preludeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        ))

        for script in toInject {
            let injectionTime: WKUserScriptInjectionTime =
                script.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd
            ucc.addUserScript(WKUserScript(
                source: Self.wrap(script),
                injectionTime: injectionTime,
                forMainFrameOnly: true,
                in: world
            ))
        }

        if DeveloperSettings.shared.verboseTabLifecycleLogging {
            Log.web.info("[UserScripts] injected \(toInject.count, privacy: .public) script(s)")
        }
    }

    // MARK: - CRUD (used by the authoring UI — Phase 2 — and the AI path — Phase 3)

    /// Adds or replaces a script (matched by id), persists, and notifies. Returns the validation result so
    /// callers can surface failures; an invalid script is still stored (so the user can fix it) but will
    /// not be injected until it validates.
    @discardableResult
    func upsert(_ script: UserScript) -> UserScriptValidation {
        ensureLoaded()
        let validation = UserScriptValidator.validate(script)
        if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[idx] = script
        } else {
            scripts.append(script)
        }
        persistAndNotify()
        return validation
    }

    func remove(id: UUID) {
        ensureLoaded()
        scripts.removeAll { $0.id == id }
        persistAndNotify()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        ensureLoaded()
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[idx].isEnabled = enabled
        persistAndNotify()
    }

    /// Global master toggle.
    func setGloballyEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        NotificationCenter.default.post(name: UserScriptNotifications.didChange, object: nil)
    }

    private func persistAndNotify() {
        UserScriptStore.save(scripts)
        NotificationCenter.default.post(name: UserScriptNotifications.didChange, object: nil)
    }

    // MARK: - Injected JavaScript

    /// Defines `window.__searxlyUS.match(pattern, url)` in the isolated content world. Implements the
    /// subset of Chrome match-pattern semantics we accept: `<all_urls>`, `<scheme>://<host><path>` where
    /// scheme is `*`/`http`/`https`, host is `*`, `*.domain`, or a literal, and path is a `*` glob.
    private static let preludeSource: String = """
    (function () {
        'use strict';
        var ns = (window.__searxlyUS = window.__searxlyUS || {});
        if (ns.match) { return; }

        function globToRegExp(glob) {
            var esc = glob.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*');
            return new RegExp('^' + esc + '$');
        }

        ns.match = function (pattern, url) {
            try {
                if (pattern === '<all_urls>') { return /^https?:\\/\\//.test(url); }
                var m = /^(\\*|https?):\\/\\/([^\\/]+)(\\/.*)$/.exec(pattern);
                if (!m) { return false; }
                var scheme = m[1], host = m[2], path = m[3];
                var u = new URL(url);

                if (scheme === '*') {
                    if (u.protocol !== 'http:' && u.protocol !== 'https:') { return false; }
                } else if (u.protocol !== scheme + ':') {
                    return false;
                }

                if (host !== '*') {
                    if (host.indexOf('*.') === 0) {
                        var base = host.slice(2);
                        if (u.hostname !== base && !u.hostname.endsWith('.' + base)) { return false; }
                    } else if (u.hostname !== host) {
                        return false;
                    }
                }

                var pathToTest = u.pathname + u.search;
                if (!globToRegExp(path).test(pathToTest) && !globToRegExp(path).test(u.pathname)) {
                    return false;
                }
                return true;
            } catch (e) {
                return false;
            }
        };
    })();
    """

    /// Wraps a validated script body: (1) a host-match guard that early-returns when the current URL does
    /// not match any of the script's patterns, then (2) a sandbox scope that shadows network / native /
    /// extension globals with throwing stubs so bare references in the body resolve to the stubs. eval and
    /// the Function constructor are NOT shadowable here (they are reserved/special); UserScriptValidator
    /// rejects those statically instead.
    private static func wrap(_ script: UserScript) -> String {
        let patternsJSON = (try? JSONEncoder().encode(script.matchPatterns))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // Name appears in a `//` line comment below — strip anything that could break out of it.
        let safeName = script.name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        return """
        (function () {
            'use strict';
            try {
                var __patterns = \(patternsJSON);
                var __href = location.href;
                var ns = window.__searxlyUS;
                if (!ns || !ns.match) { return; }
                if (!__patterns.some(function (p) { return ns.match(p, __href); })) { return; }
            } catch (e) { return; }

            // Sandbox scope: shadow network / native-bridge / extension globals.
            (function () {
                'use strict';
                var fetch = function () { throw new Error('Searxly: network is disabled in userscripts'); };
                var XMLHttpRequest = function () { throw new Error('Searxly: network is disabled in userscripts'); };
                var WebSocket = function () { throw new Error('Searxly: network is disabled in userscripts'); };
                var EventSource = function () { throw new Error('Searxly: network is disabled in userscripts'); };
                var importScripts = function () { throw new Error('Searxly: remote code is disabled in userscripts'); };
                var webkit = undefined, chrome = undefined, browser = undefined;
                try {
                    // ===== userscript: \(safeName) =====
        \(script.body)
                    // ===== end userscript =====
                } catch (e) {
                    try { console.error('[Searxly userscript] ' + (e && e.message ? e.message : e)); } catch (_) {}
                }
            })();
        })();
        """
    }
}
