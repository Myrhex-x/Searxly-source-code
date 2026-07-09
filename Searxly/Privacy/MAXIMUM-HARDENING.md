# Searxly Maximum — WebKit hardening pass

All items below are **Searxly Maximum only** (gated on `Edition.isMaximum` or Maximum-Privacy). The base
app is unchanged — the Maximum branches are dead-stripped there because `Edition.isMaximum` is a compile
constant `false`. Both schemes build green.

## 1. Security-level slider (Standard / Safer / Safest)
`MaximumSecurityLevel` + `MaximumSecurity` (`Privacy/MaximumSecurityLevel.swift`), UI in
`PrivacySettingsView.securityLevelSection`.
- **Safest** denies content JavaScript on the **web** via the per-navigation `WKWebpagePreferences`
  (`WebViewRepresentable+Navigation`), keeping JS for **loopback** so the local SearXNG search UI still
  works. No JS ⇒ no JIT ⇒ the entire JS exploit surface (the classic Tor-deanonymisation vector) is gone.
- **Safer** drops WebGL / WebGPU / WebAssembly (high exploit + entropy value) via `strictMaximumHardeningJS`.
- **Honest limit:** WKWebView exposes no public "disable JIT while keeping JS" knob, so "kill the JIT" is
  implemented as "kill JS on the web." Safer's API removal is JS-level (a fresh-realm escape can still find
  the originals — the WKWebView ceiling).

## 2. Out-of-process egress is covered (audit)
WKWebView networks in a **separate `com.apple.WebKit.Networking` process**. We route via
`WKWebsiteDataStore.proxyConfigurations` (a SOCKS5 to the bundled Tor), which the Networking process
honours — so subresources, favicons, media, etc. all traverse Tor, not just the app's `URLSession`. The
proxy has **no direct fallback (fail-closed)**, and the kill switch (`PrivacyGate.shouldBlockWebNavigation`)
blocks navigations until protection is verified up — a second, independent layer. Per-tab SOCKS credentials
give per-tab circuit isolation. **Conclusion: covered.** (VPN mode is whole-device, so every process rides it.)

## 3. WebRTC + speculative networking off
- **WebRTC** was already neutered in Maximum-Privacy (`RTCPeerConnection` & friends read `undefined`), so a
  page can't gather ICE candidates to leak the real IP past Tor's TCP-only SOCKS.
- **NEW:** `strictMaximumHardeningJS` strips `dns-prefetch` / `preconnect` / `prefetch` / `prerender` hints
  (existing + injected, via a `MutationObserver`) and sets `x-dns-prefetch-control: off`, so no connection
  or DNS lookup fires ahead of a real navigation.

## 4. Uniform identity (not unique)
- **Timezone** already forced to UTC.
- **NEW:** `navigator.language` / `navigator.languages` pinned to `en-US` / `['en-US','en']` so locale can't
  narrow you down.
- **Fonts** already farbled (measureText noise + FontFaceSet allow-list).
- **Honest limit:** the `Accept-Language` HTTP header is set by the OS and isn't reachable from WKWebView's
  public API — this covers the JS surface, not that header.

## 5. State partitioning / always ephemeral
Maximum now uses a **non-persistent `WKWebsiteDataStore` for every tab**, including the VPN lane (previously
standard tabs in VPN mode fell through to a persistent on-disk store). Nothing (cookies / cache /
localStorage) is written to disk or shared across sites; everything is RAM-only and gone on quit. Combined
with per-tab circuits, cross-site correlation via a shared cache is closed.

## 6. OS-level leak surface
- **No third-party crash/analytics SDKs** (Sentry/Crashlytics/Firebase/etc.) and no
  `NSSetUncaughtExceptionHandler` / MetricKit crash upload — verified. Nothing phones home.
- **Cold start is fail-closed:** Maximum forces `.maximum` in `PrivacyManager.init` and arms `PrivacyGate`
  at launch, so any webview created before Tor is up has its navigations blocked (no pre-tunnel leak).
- **Honest residual (App Sandbox ceiling):** Apple's own crash reporter (`~/Library/Logs/DiagnosticReports`),
  the LSQuarantine DB, and OS OCSP/revocation checks are written/made by the OS outside our container. We
  minimise what we hand the OS; we can't scrub what it stores or fetches elsewhere. Stated plainly on the
  security page.

## 7. External-app handoff + clipboard
- **External handoff:** a link to another app (`mailto:` / `magnet:` / `tel:` / custom scheme) is no longer
  silently followed — Maximum shows a blocking confirmation (`confirmExternalAppHandoff`) warning that the
  other app ignores Tor and can reveal the real IP, and only opens on explicit consent.
- **Clipboard:** `AntiForensics.installClipboardHardening()` clears the system pasteboard on quit so a
  copied password/URL doesn't linger for the next app or sync via Universal Clipboard after close.
  **Honest limit:** while running, a copy can still be picked up by Universal Clipboard — macOS has no
  app-level switch to disable that.

---

# Round 2 — deeper leak vectors

## 8. Timing side-channel + fingerprint defense
In `strictMaximumHardeningJS`: `performance.now()` is coarsened to 100 ms and `SharedArrayBuffer` /
`crossOriginIsolated` are made unavailable — blunting both high-resolution timing fingerprinting and
Spectre-class cross-origin reads (the standard Tor Browser mitigation).

## 9. Web Worker fingerprinting bypass closed
A page could move OffscreenCanvas / WebGL / audio reads into a Web Worker, where the main-thread farbling
never reached, and read a clean fingerprint. The classic `Worker` / `SharedWorker` constructors are now
wrapped (`workerFarblingSource` prepended via an `importScripts` blob) so worker scope gets the same
farbling + timer coarsening. **Limit:** module workers can't `importScripts`, so they fall back (WKWebView
ceiling).

## 10. Downloaded-file open safety
`AntiForensics.confirmOpenDownloadedFile` — opening a downloaded file from the Downloads sheet now warns
first in Maximum (a document can fetch remote resources on open, outside Tor — the classic Tor-Browser
deanonymisation vector), and only opens on consent. PDFs opened in-tab already inherit the security level
(JS off at Safest).

## 11. speechSynthesis voices standardized
`speechSynthesis.getVoices()` returns `[]` in Maximum — the installed-voice list was a stable fingerprint.

## 12. New Identity (⌘⇧U)
`BrowserState.newIdentity()` + a Maximum-only menu command: closes all tabs, clears website data, and
rotates all Tor circuits (`TorManager.newCircuit()` → NEWNYM) for a fresh, unlinkable session — the
Tor-Browser staple.

## 13. Idle auto-lock — ALREADY PRESENT
`AppLockManager` already has an inactivity auto-lock (`inactivityLockMinutes`, default 5, an `NSEvent`
activity monitor + timer, plus lock-on-sleep / screen-lock). Maximum gets it on by default via the
fresh-install App Lock default. No new code needed.

---

# Round 3 — engine-level (Tier 1: WebKit SPI, no fork)

Goal: move hardening from *detectable JS shims* to *real engine state*, to be unambiguously ahead of
Brave Origin on fingerprinting/exploit surface — without a custom engine (Tor-Browser parity is a non-goal).

## 14. Engine-level feature disabling — `WebViewFactory.applyEngineHardening`
Enumerates `WKPreferences._experimentalFeatures` / `_internalDebugFeatures` and disables the
privacy-relevant ones **in the engine** via `_setEnabled:for…Feature:` — WebRTC/PeerConnection,
MediaStream/Devices/Recorder, Gamepad, WebNFC/Serial/HID/USB/Bluetooth, Battery, NetworkInformation,
prefetch/prerender/speculation (all levels); plus WebGL/WebGPU/WASM/OffscreenCanvas at **Safer/Safest**.
Engine-off is undetectable + unbypassable, unlike the JS shims (which remain the floor).

## 15. Real JIT-off for Safer/Safest — WebKit Lockdown Mode
`makeWebView` turns on WebKit's Lockdown ("captive portal") mode on `WKWebpagePreferences` via SPI at
Safer/Safest — engine-level **JIT-off**, the #1 exploit mitigation and the exact thing JS can't do. Safer
now = "JIT off, JS still works"; Safest still also denies web JS via the nav delegate.

## SPI safety + honest caveat
Every SPI call is guarded by `responds(to:)`; "disable" uses the nil-argument trick (a nil `id` arg reads
as `BOOL false`). If a symbol is gone on a future WebKit, it **no-ops** and the JS shims/JS-off remain the
floor — it cannot crash or regress. **Needs a runtime check** (can't be verified at compile time): confirm
which toggles actually land on the shipping macOS/WebKit (feature KEYS vary by version; STABLE features
aren't in the experimental lists, so those stay covered only by the JS floor), and confirm the Lockdown
selector name is current. Fails safe either way.
