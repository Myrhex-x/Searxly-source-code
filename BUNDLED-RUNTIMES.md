# Bundled runtimes — security update cadence

Searxly ships three third-party runtimes **inside the app bundle**. Because they run on the user's
machine (and Tor is network-facing), an out-of-date bundled runtime is a real security exposure.
This file is the checklist for keeping them current.

| Runtime | Why it's bundled | Version pinned in | Built/fetched by |
|---|---|---|---|
| **Tor** (+ libevent) | `.onion` routing, leak-resistant SOCKS5 | `Searxly/Tor/TorRuntimeConfig.swift` → `bundledVersion` | `scripts/fetch-tor-runtime.sh` |
| **SearXNG** | the local private search engine | `Searxly/Services/SearxngRuntimeConfig.swift` → `bundledVersion` | `scripts/build-searxng-runtime.sh` |
| **Python 3.12** (+ deps: lxml, msgspec, PyYAML, MarkupSafe, …) | runs SearXNG | with the SearXNG runtime above | `scripts/build-searxng-runtime.sh` |

## When to update

- **Tor:** highest priority. Watch the Tor Project release announcements / security advisories. Ship a
  bump on any stable security release. Tor talks to the network, so a known-vulnerable bundled `tor` is
  the most urgent of the three.
- **SearXNG:** track upstream releases; bump on security fixes or scraper breakage. (A stale SearXNG is
  usually a *quality* problem — broken engines — but can also carry security fixes in its deps.)
- **Python + native deps (lxml etc.):** bump when CPython or a bundled C-extension dep gets a CVE.
  `lxml` (libxml2/libxslt) is the one most likely to have parsing CVEs since it processes engine HTML.

## Update procedure

1. Re-run the relevant script (`fetch-tor-runtime.sh` / `build-searxng-runtime.sh`) against the new
   upstream version.
2. Bump `bundledVersion` in the matching `*RuntimeConfig.swift` so Settings shows the new version and any
   in-app migration logic keys off it.
3. Confirm the rebuilt binaries are **arm64** (Apple Silicon only — see `deployment_target` notes) and
   re-sign as part of the app build.
4. Smoke-test on device: local SearXNG starts and returns results; a `.onion` page loads over Tor.

## Notes

- All three are launched by the **unsandboxed `SearxlyHelper` XPC service**, whose file operations are
  now restricted to `~/searxng-local` + Searxly's Application Support, and whose connections require the
  caller to be signed by the same team (see `SearxlyHelper/`). Keeping the runtimes current is the other
  half of that boundary.
- SearXNG binds to `127.0.0.1` only for normal users; Tor's SOCKS/Control ports are localhost-only.
