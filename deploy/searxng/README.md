# Searxly hosted SearXNG instance

The iOS app can't run SearXNG locally (no Python/subprocess on iOS), so it searches a **remote**
instance. This is that instance — the one thing currently gating real search results on iOS, because
public instances rate-limit/disable the JSON API the native SERP needs.

It's a standard, hardened SearXNG stack: **SearXNG + Valkey (redis, for the limiter) + Caddy (auto-TLS)**,
with the **`json` format enabled** so Searxly's native results page works.

## Deploy (on the server)

1. **DNS** — point `search.searxly.app` (or your chosen host) at the server's IP. Update the hostname in
   `Caddyfile` and `SEARXNG_BASE_URL` in `docker-compose.yml` to match.
2. **Copy this folder to the server** and run:
   ```bash
   cd deploy/searxng
   ./deploy.sh
   ```
   It generates a `secret_key`, pulls images, and starts the stack. Caddy fetches a TLS cert automatically.
3. **Verify the JSON API** (this is exactly what the iOS app calls):
   ```bash
   curl -fsS 'https://search.searxly.app/search?q=test&format=json' | head -c 200; echo
   ```
   A JSON body = you're done.

## Point the app at it

- In-app: **Settings ▸ Search instance** → `https://search.searxly.app`
- As the shipped default: set `SearchSettings.placeholderInstance` in `SearxlyiOS/Settings/SearchSettings.swift`.

## Notes

- **Privacy:** a shared instance sees queries server-side (the unavoidable trade vs. the macOS per-device
  local instance). Mitigations already on: `limiter`, `image_proxy`, proxy query-logging disabled.
- **Abuse/cost:** the public endpoint attracts bots — keep `limiter: true`, and consider Caddy-level rate
  limiting + Cloudflare in front.
- **Engines:** keep `searxng/settings.yml` engines in parity with the macOS runtime so results match.
- **Web theme:** the native iOS SERP uses the JSON API, so the web UI theme is cosmetic here. The
  monochrome theme in `LocalSearxng/custom/` can be mounted if you want the web UI on-brand too.
