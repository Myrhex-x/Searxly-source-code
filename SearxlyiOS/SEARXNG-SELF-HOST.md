# Self-hosting a SearXNG instance for Searxly iOS

iOS **cannot** run the bundled native SearXNG the macOS app uses (no fork/exec, no Python
interpreter, App Review 2.5.6). The iOS app therefore searches a **remote** SearXNG instance.

- **Shipped default:** `https://search.searxly.app` (`SearchSettings.defaultInstance`) — our hosted
  instance, which the native SwiftUI SERP consumes via the JSON API.
- **Custom instance:** Settings ▸ Search ▸ **Advanced — search instance** accepts any SearXNG
  instance with the `json` output format enabled (gated by `SearchSettings.allowsCustomInstance`).
- **Fallbacks:** when on the default instance, the client rotates to public JSON-enabled backups if
  the primary is down (`SearchSettings.fallbackInstances`). A user-supplied custom instance is
  respected as-is and never rotated.

The recipe below stands up an instance of your own (the same shape as our hosted one).

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
      - SEARXNG_BASE_URL=https://search.example.com/   # your public URL
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
  formats:                         # MUST include json — the native SERP consumes it
    - html
    - json
# Engines: our hosted instance currently runs google (CSE), bing, brave, mojeek, wikipedia.
# Any engine set works; broader coverage → better blended results.
```

## 3. TLS reverse proxy

Front the container with Caddy or nginx terminating TLS for your domain → `127.0.0.1:8080`.
Caddy one-liner:

```
search.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

## 4. Point the app at it

Settings ▸ Search ▸ **Advanced — search instance** → `https://search.example.com`

## 5. Verify

```bash
curl -fs "https://search.example.com/search?q=test&format=json" | head -c 200
```

A JSON body confirms the JSON API is on. If you get HTML or a 403, enable the `json` format in
`settings.yml` — the app rejects HTML responses (`SearxngClient.notJSON`).

## Notes

- **Privacy:** a shared remote instance sees its users' queries server-side — that's the unavoidable
  trade vs. the macOS per-device local instance. Self-hosting puts that trust in your own server.
  Mitigations either way: `limiter`, `image_proxy`, no query/access logging.
- **Abuse/cost:** a public endpoint attracts bots — keep `limiter: true`, rate-limit at the proxy,
  and keep the image current (upstream-engine breakage is usually fixed by a runtime refresh).
