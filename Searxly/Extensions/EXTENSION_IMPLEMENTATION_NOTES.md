# Extensions — Implementation Notes (Searxly)

Searxly's extension story has **two lanes** under one future "Extensions" roof. This folder currently
implements **Lane B**. Lane A is documented here as the deferred future option.

| | **Lane A — Curated WebExtensions** | **Lane B — AI-authorable Userscripts** (this folder) |
|---|---|---|
| Engine | `WKWebExtension` (macOS 15.4+) | `WKUserScript` (works on macOS 15.0) |
| Source | Searxly-vetted gallery, signed | User-authored or generated on-device from a prompt |
| Trust | Third-party, signature-gated | First-party, the user's own code, reviewed before enable |
| API | Full `chrome.*` | Minimal; **no** `chrome.*`, **no** network, **no** native bridge |
| Status | **Phase 0 spike landed** (engine compiles; runtime via Dev button) | **Building** (Phases 1–2 landed) |

> **Market model (decided):** Lane A is a **curated free gallery** — Searxly vets and signs only
> open-source / redistributable extensions (uBlock Origin Lite, Dark Reader, Bitwarden, …) that are
> tested to work in WebKit. **Not** a mirror of the Chrome Web Store: redistributing CWS `.crx` files
> violates their ToS, and most extensions are copyrighted. No open user-submitted marketplace.

**Filename note:** named `EXTENSION_IMPLEMENTATION_NOTES.md` (not the generic `IMPLEMENTATION_NOTES.md`)
to avoid Xcode "Multiple commands produce" CpResource collisions, same as `AD_BLOCKER_IMPLEMENTATION_NOTES.md`.

---

## Why Lane B exists (and is not a WebExtension)

AI-generated code cannot pass through a curated, signed gallery — it is generated on demand, for one
user. Forcing it into the WebExtension/gallery trust model would break that model. So AI-authored
extensions live in a separate, tightly-sandboxed **first-party userscript lane**: the user's own code,
which they can read and edit, scoped to specific sites, with a minimal capability surface.

This is *more* private than a cloud-assisted equivalent: generation is on-device, the code never leaves
the Mac, and every line is inspectable.

---

## Files

- `UserScript.swift` — the model + shared limits (`UserScriptLimits`) + match-pattern structural check.
- `UserScriptValidator.swift` — static validation (Layer 3 of the defense). Rejects forbidden constructs.
- `UserScriptStore.swift` — persistence in its own resilient file `~/Library/Application Support/Searxly/UserScripts.json` (isolated from AppData.json — the password-vault lesson).
- `UserScriptManager.swift` — `@MainActor` singleton. Registry, persistence, `prepare()`, `apply(to:mode:)`, CRUD, and the injected JS (match prelude + sandbox wrapper).

**Integration points (deliberately minimal, mirroring AdBlockManager):**
- `SearxlyApp.init()` → `UserScriptManager.shared.prepare()`.
- `WebViewFactory.makeWebView(mode:)` → `UserScriptManager.shared.apply(to: configuration, mode: mode)`.
  This single chokepoint covers new tabs, private/onion (excluded), and hibernation wake (`BrowserTab.wakeUp`).

No changes needed in tab lifecycle, PrivacyManager, or Persistence (Lane B keeps its own file).

---

## The jailbreak / abuse defense (layered — no single layer is the whole story)

1. **Input cap** — the user's NL prompt is capped at `UserScriptLimits.promptCharLimit` (280). A real
   request is short; longer input is almost always an injection/roleplay payload. (Phase 3 / authoring UI.)
2. **Structured output** — the on-device model emits a *userscript schema*, not free chat, so the prompt
   box cannot be repurposed as a general LLM. (Phase 3.)
3. **Static validation** (`UserScriptValidator`) — rejects `eval`, the `Function` constructor, dynamic
   `import()`, `.constructor`, `globalThis`, `window/self/top.fetch|XMLHttpRequest|WebSocket`, `sendBeacon`,
   `importScripts`, `webkit.messageHandlers`, `chrome.*`/`browser.*` extension APIs, `<script>` injection,
   and `window.open`. Also enforces body/name/pattern caps.
4. **Runtime sandbox wrapper** (`UserScriptManager.wrap`) — the body runs inside a scope where bare
   `fetch`/`XMLHttpRequest`/`WebSocket`/`EventSource`/`importScripts`/`webkit`/`chrome`/`browser` are
   shadowed by throwing stubs, behind a host-match guard. (`eval`/`Function` are reserved and cannot be
   var-shadowed — they are blocked statically by Layer 3 instead.)
5. **Isolated content world** — scripts run in `WKContentWorld.world(name: "SearxlyUserScripts")`: they
   cannot see the page's JS globals and cannot reach Searxly's native message handlers (those are in the
   `.page` world — e.g. the wallet bridge).
6. **Standard tabs only** — never injected on Private or Onion/Tor tabs (a script there could
   deanonymize the session). Same gate the wallet provider uses.
7. **Human review** — the generated/edited code is shown and must be explicitly enabled per-site;
   nothing auto-runs. Only scripts that are *both* enabled *and* currently pass validation are injected.

**Honest residual risk:** token scanning of JS is imperfect, and an isolated content world still exposes
the standard web platform (`fetch` is a real global there). A determined, hand-obfuscated script could
in principle evade the static scan and reach a non-shadowed escape. That is why the layers stack, and why
"these are the user's own reviewed scripts" is part of the model. A future hardening option is to run
bodies in a separate realm (sandboxed iframe / Worker) for a true network kill-switch.

---

## Behavior notes

- **Apply timing:** scripts are added to the `WKWebViewConfiguration` at webview creation. Changes to the
  list take effect on **new tabs immediately** and on **existing tabs after their next navigation/reload**
  (WKUserScripts can't be removed individually post-add) — same model as the ad blocker. The
  `UserScriptNotifications.didChange` notification is posted on every change for the UI to react.
- **Match patterns:** Chrome-style subset — `<all_urls>`, or `<scheme>://<host><path>` where scheme is
  `*`/`http`/`https`, host is `*` / `*.domain` / literal, path is a `*` glob. Matching runs in the prelude.
- **Master toggle:** `UserDefaults` key `userScriptsEnabled` (default true). With no scripts it is a no-op.

---

## Roadmap

- **Phase 1 — runtime (DONE):** model, validator, store, manager, factory + app wiring.
- **Phase 2 — authoring UI (DONE):** `Views/Features/Settings/ExtensionsSettingsView.swift` — master
  toggle, installed list with per-script enable + Manual/AI + On/Off/Won't-run badges, create/edit/delete,
  and an editor sheet (name, match patterns, run timing, body) with **live validation** that lists every
  reason a script can't run. Registered as the `.extensions` category in `SettingsView` (Features group).
  Built only from the SettingsLayout primitives (monochrome, on-brand).
- **Phase 3 — AI authoring:** prompt box (280-char cap) → `FoundationModels` guided generation (macOS 26+,
  `AppleIntelligenceProvider`; `CloudIntelligenceProvider`/Ollama as opt-in fallback with egress
  disclosure) → validate → review → enable.
- **Phase 4 — polish:** en/fr localization, monochrome brand pass, `/security-review` of the codegen path.
### Lane A — curated WebExtension gallery (real Chrome/Firefox extensions)

- **Phase 0 — engine spike (DONE):** `Extensions/LaneA/WebExtensionSpike.swift`. Self-contained, Dev-Mode
  only, gated `@available(macOS 15.4, *)`. Writes a throwaway MV3 extension to temp, loads it, attaches to
  an offscreen webview via minimal tab/window adapters, and checks a content script ran. **Run it:** enable
  Developer Mode → Settings → Features → Extensions → "Run WebExtension spike". Compiles clean; runtime
  check requires a macOS 15.4+ run.
- **Phase 1 — engine wired in, flag-gated (DONE):** `Extensions/LaneA/`:
  - `ExtensionFeatures.laneAEnabled` — master flag, **default OFF** (`extLaneAEnabled`). While off, the
    controller is never created.
  - `ExtensionManager` — `@available(15.4) @MainActor` singleton owning the ONE shared
    `WKWebExtensionController`. `configure(_:mode:)` attaches it to standard-tab configs (the
    `WebViewFactory` hook, guarded by flag + `#available`); `load(directory:)` loads/activates an
    extension (broad host grant for bring-up — real permission UI is Phase 2); `registerTab`/`setActiveTab`
    for the live tabs API.
  - **Adapter-wrapper design:** `WebExtensionTabAdapter` / `WebExtensionWindowAdapter` wrap the webview —
    `BrowserTab`/`BrowserState` carry **no** WebExtension or 15.4 coupling.
  - Dev panel (ExtensionsSettingsView): Lane A flag toggle + "Load test extension" + the spike.
  - Verified: builds clean. Attaching the controller is what drives **content-script injection** on
    standard tabs.
- **Phase 2 — permission model (DONE):** the privacy posture, fully compile-verified.
  - `WebExtensionControllerDelegate` — set as `controller.delegate`. **Default-deny:** every runtime
    permission escalation (`promptForPermissions` / `…ToAccess` / `…MatchPatterns`) returns the empty set,
    logged. No silent grants.
  - `ExtensionManager.load(directory:id:grantRequestedHosts:)` — **default-deny** (was: grant-all in P1).
    Grants only what's persisted in `WebExtensionPermissionStore`, keyed by `context.uniqueIdentifier`.
    `grantRequestedHosts:true` is the Dev/bring-up path (grants the manifest's requested hosts + records).
  - `grantRequestedHosts(for:)` / `revokeAll(for:)` + `WebExtensionPermissionStore` (own resilient
    `WebExtensionGrants.json`) are the hooks the Phase 3 approval UI plugs into.
  - API gotcha caught: `WKWebExtension.MatchPattern(string:)` is a **throwing** init (not failable).
- **Phase 3a — approval UI (DONE):** ExtensionsSettingsView now lists installed Lane A extensions
  (`ExtensionManager.snapshots()` → `LaneAExtensionSnapshot`, a 15.0-safe struct so the 15.0 view needn't
  import 15.4 types) with their requested permissions/hosts, an Access N/M badge, and **Grant / Revoke**
  buttons (`grantRequestedHosts(forLoadedID:)` / `revokeAll(forLoadedID:)`). Lives in the Dev section for
  now (install path is Dev-only until the gallery); query is Dev-gated so the controller isn't
  instantiated for normal users. Builds clean.
- **Phase 3b — normal-user store + install + persistence (DONE):** the Extensions settings pane now has a
  **"Browser extensions"** section reachable WITHOUT Dev Mode.
  - `ExtensionInstallStore` (`ExtensionInstalls.json`) tracks installs; packages live under
    `Application Support/Searxly/Extensions/<id>/`. `ExtensionBootstrap.run()` (15.0-safe; called from
    `SearxlyApp.init`) reloads them at launch — and **never instantiates the controller unless the user
    has actually installed one** AND is on 15.4.
  - `ExtensionManager.installBuiltInDemo()` / `reloadInstalled()` / `uninstall(loadedID:)`. Install grants
    the extension's requested hosts (explicit user consent) + flips the engine flag on; uninstall removes
    files + grants and flips the flag off when nothing's left.
  - Built-in **"Searxly Demo"** extension (generated to disk): a content script that shows a brief
    auto-fading "✓ Searxly extension active" badge — so a normal user can install it and immediately see
    extensions working. uBlock Origin Lite / Dark Reader shown as **"Coming soon"** (need the signed catalog).
  - Store UI: installed cards (Active/No-access badge, requested permissions/hosts, Grant/Revoke/Remove) +
    available cards (Install / Coming soon). Builds clean.
- **Content-script injection fix (DONE, user-confirmed working):** content scripts do **not** inject from
  the controller attachment alone — the tab must be registered via `controller.didOpenTab`. So
  `WebViewFactory.makeWebView` (standard path) now calls `ExtensionManager.shared.registerTab(webView,
  active: true)` right after creating the webview (flag-gated + 15.4). `registerTab` also prunes adapters
  whose webview has deallocated, so they don't accumulate.
- **Per-extension view + toggle via the address-bar globe (DONE):** `PrivacyStatusView` (the globe popover)
  lists each installed extension under "Extensions on \<host\>", each with a per-site on/off switch + a
  Running/Paused/No-access subtitle — so you can see what's enabled and pause an individual one here.
  Persisted **per-extension** in `ExtensionSiteStore` (15.0-safe UserDefaults map `extensionID → [pausedHost]`);
  enforced by `ExtensionManager.setExtensionEnabled(_:extensionID:forHost:)` →
  `context.deniedPermissionMatchPatterns` (`*://host/*` + `*://*.host/*`, keyed off `context.uniqueIdentifier`),
  re-applied on every load. Reload an open page to apply.
- **Full-page marketplace (DONE):** `TabKind.extensions` (new utility-page kind, like Passwords/Bookmarks)
  → rendered by `ContentView+Sheets.utilityTabContent` as `Views/Features/ExtensionsMarketplaceView.swift`
  (full-page: Installed + Discover cards, install/grant/revoke/remove, requires-15.4 fallback). Opened via
  `.showExtensionsTabRequested` notification → `BrowserState.ensureAndSelectUtilityTab(.extensions)`;
  entry point = "Open the Extensions page" button in the Settings → Extensions pane. Adding the TabKind
  case did NOT break other switches (codebase uses generic `isUtility`/`utilityIcon`). Builds clean.
- **Catalog client (DONE, client side):** `Extensions/LaneA/ExtensionCatalog.swift` —
  `ExtensionCatalogClient.fetch()` pulls `catalog.json` from searxly.app (graceful `[]` on failure, so the
  marketplace falls back to the built-in demo + "Coming soon"); `downloadVerifiedPackage` downloads the
  `.zip`, checks **SHA-256** (mandatory) + **Ed25519 signature** (once `publicKeyBase64` is set), and saves
  it. `ExtensionManager.installFromCatalog(_:)` records + loads it (`WKWebExtension` loads a `.zip`
  resourceBaseURL directly; `reloadInstalled` now handles dir OR zip). The marketplace's Discover section
  lists catalog entries when the catalog is reachable. `LaneAExtensionSnapshot.extensionID` added so
  install-state is matched by id.
- **Menu entry (DONE):** App menu → "Extensions" (CommandGroup after `.toolbar`) posts
  `.showExtensionsTabRequested`. (Settings button still works too.)
- **Phase 3c (only remaining):** full `chrome.tabs`/`windows` CLOSE/ACTIVATE events (confirm
  `NS_REFINED_FOR_SWIFT` `didActivateTab`/`didCloseTab` on a 15.4 runtime; needs a proper BrowserState
  close hook to avoid firing on hibernation). Not needed by content-script / content-blocker extensions.

### Server side — to publish the real catalog (your ops, not code)
1. Host `https://searxly.app/extensions/catalog.json`:
   ```json
   { "version": 1, "extensions": [
     { "id": "ublock-origin-lite", "name": "uBlock Origin Lite", "description": "…",
       "version": "1.0.0", "author": "…", "license": "GPL-3.0",
       "icon": "shield.lefthalf.filled", "permissionsSummary": "…",
       "package": "https://searxly.app/extensions/ublock-origin-lite-1.0.0.zip",
       "sha256": "<hex of the zip bytes>", "signature": "<base64 Ed25519 over the zip bytes>" } ] }
   ```
2. Each `package` is a `.zip` of a WebExtension (containing `manifest.json`). Only ship ones you have the
   right to redistribute (open-source) and that you've tested in WebKit.
3. Generate an Ed25519 keypair; put the **base64 public key** in `ExtensionCatalogClient.publicKeyBase64`
   (then signatures become mandatory) and sign each zip's bytes with the private key.

**Key API facts the spike nailed down (macOS 27 SDK):**
- All `WKWebExtensionTab` / `WKWebExtensionWindow` methods are **`@optional`** — minimal conformance works.
- Every `WKWebExtension*` type is **`MainActor`-isolated** (`WK_SWIFT_UI_ACTOR`) → managers/adapters must be `@MainActor`.
- Swift nests several types under `WKWebExtension`: it's **`WKWebExtension.MatchPattern`** (not `WKWebExtensionMatchPattern`), `WKWebExtension.WindowType`, etc.
- Load path: `try await WKWebExtension(resourceBaseURL:)` → `WKWebExtensionContext(for:)` → grant via `context.grantedPermissionMatchPatterns = [.allHostsAndSchemes(): .distantFuture]` → `try controller.load(context)`.
- Hook to webviews: `wkWebViewConfiguration.webExtensionController = controller`; tell the controller about UI via `controller.didOpenWindow(_:)` / `didOpenTab(_:)`.

---

## Privacy invariants (enforced)

- Userscript execution never touches Private or Onion/Tor tabs.
- No network by default — the runtime shadows network globals and the validator rejects the escapes.
- Generation (Phase 3) is on-device first; any cloud path is opt-in and disclosed, like the rest of Searxly.
- Everything is local: scripts live in a local file, run locally, and are fully inspectable by the user.
