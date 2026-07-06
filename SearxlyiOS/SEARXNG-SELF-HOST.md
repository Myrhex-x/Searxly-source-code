# Self-hosting the Searxly SearXNG instance (iOS Phase 2)

iOS **cannot** run the bundled native SearXNG the macOS app uses (no fork/exec, no Python interpreter,
App Review 2.5.2). The iOS app therefore searches a **remote** SearXNG instance. Until our own is live
it points at a public placeholder (`https://searx.be`); set `instanceURL` in **Settings ▸ Search
instance** (or change `SearchSettings.placeholderInstance`) to our endpoint once it's up.

This is the recipe to stand one up on our own server (e.g. the gateway VPS). It mirrors the macOS
runtime: upstream SearXNG run via `searx.webapp`, with **both** `html` and `json` output formats
enabled (the `json` format is what a future native SwiftUI SERP on iOS will consume, exactly like macOS).

## 1. docker-compose (simplest on a VPS)

```yaml
# /opt/searxng/docker-compose.yml
services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"      # front with a TLS reverse proxy (below)
    volumes:
      - ./searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=https://search.searxly.app/   # our public URL
```

## 2. settings.yml essentials

```yaml
# /opt/searxng/searxng/settings.yml
use_default_settings: true
server:
  secret_key: "REPLACE_WITH_$(openssl rand -hex 32)"
  limiter: true                    # basic bot/abuse protection
  image_proxy: true                # proxy result thumbnails (privacy)
search:
  formats:                         # MUST include json for the native SERP path
    - html
    - json
# Engines: keep parity with the macOS instance (broad coverage).
# Re-broadened set per project history: google, duckduckgo, brave, startpage, qwant, wikipedia.
```

> Keep the engine set in sync with the macOS runtime so iOS and macOS return comparable results.

## 3. TLS reverse proxy

Front the container with Caddy or nginx terminating TLS for `search.searxly.app` → `127.0.0.1:8080`.
Caddy one-liner:

```
search.searxly.app {
    reverse_proxy 127.0.0.1:8080
}
```

## 4. Point the app at it

- **In-app:** Settings ▸ Search instance → `https://search.searxly.app`
- **Default in code:** change `SearchSettings.placeholderInstance` to the same URL and ship.

## 5. Verify

```bash
curl -fs "https://search.searxly.app/search?q=test&format=json" | head -c 200
```

A JSON body confirms the instance is live and the JSON API (future native SERP) works.

## Notes

- **Privacy:** a single shared instance sees all users' queries server-side. That's the unavoidable
  trade vs. the macOS per-device local instance. Mitigations: `limiter`, `image_proxy`, no query
  logging (`SEARXNG_DISABLE_*` / don't enable access logs), and consider per-region instances later.
- **Abuse/cost:** the public endpoint will attract bots — keep `limiter: true`, rate-limit at the
  proxy, and watch upstream-engine rate limits (the macOS "few results" fix was a runtime/engine
  refresh, not IP/CAPTCHA — keep the image up to date).
