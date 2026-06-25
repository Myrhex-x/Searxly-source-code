# Tor / `.onion` support (onion-only, v1)

Searxly can open `.onion` hidden services by routing **only onion tabs** through a private, bundled
Tor client. Normal browsing is untouched.

## How it works
- A signed `tor` binary ships in the app at `Resources/tor-runtime/` (same model as the bundled
  SearXNG Python runtime). It is **not** committed — `build/tor-runtime/` is gitignored and produced
  by `scripts/fetch-tor-runtime.sh`, then copied into the app by the **"Bundle Tor runtime"** Xcode
  build phase.
- `SearxlyHelper` (the unsandboxed XPC service) spawns + supervises `tor` exactly like it does
  SearXNG: it generates a `torrc` under `~/Library/Application Support/Searxly/tor/`, tracks the
  process via a pidfile, and exposes start/stop/running/bootstrap over XPC
  (`SearxlyHelperProtocol.startTor` …).
- `TorManager` (`@Observable @MainActor` singleton) drives lifecycle + bootstrap progress.
- Onion tabs are a new `TabPrivacyMode.onion`. In `WebViewFactory`, that mode gives the tab a
  **non-persistent** data store with a SOCKS5 `ProxyConfiguration` pointing at Tor
  (`127.0.0.1:19050`). SOCKS5h means hostnames (incl. `.onion`) resolve at the proxy → `.onion`
  works and there is no DNS leak.
- `.onion` URLs typed/loaded anywhere are intercepted in `BrowserState.loadInWebView` and handed to
  `openOnionURL`, which bootstraps Tor (showing a placeholder) before issuing the real navigation.

## One-time setup to enable it
1. `./scripts/fetch-tor-runtime.sh` (downloads the official Tor expert bundle → `build/tor-runtime/`,
   signs `tor` with Hardened Runtime).
2. In Xcode, ensure `build/tor-runtime` is bundled — the "Bundle Tor runtime" build phase already
   rsyncs it into `Contents/Resources/tor-runtime`. (If you prefer an explicit folder reference, add
   it to the Searxly target via *Add Files → Create folder references*, like `LocalSearxng`.)
3. Make sure `tor-runtime` is included in **notarization** alongside the SearXNG runtime.
4. Keep `TorRuntimeConfig.bundledVersion` in lockstep with `scripts/fetch-tor-runtime.sh` `TOR_VERSION`.

Until the binary is present the feature degrades gracefully: `TorManager.isAvailable` is false and
onion tabs show a clear "Tor runtime is missing" message instead of failing silently.

## Honesty
This provides **network-level anonymity** (real IP hidden, `.onion` reachable, no DNS leak) but is
**not Tor Browser** — WKWebView cannot replicate Tor Browser's anti-fingerprinting. Onion tabs
surface that caveat. Stronger hardening (WebRTC/geolocation blocks, fingerprint resistance) and a
future whole-app Tor toggle are tracked as follow-ups.
