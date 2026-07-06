#!/usr/bin/env bash
#
# Bring up (or update) the Searxly SearXNG instance. Run this on the server, from this directory.
# Idempotent: safe to re-run to pull new images and restart.
#
set -euo pipefail
cd "$(dirname "$0")"

SETTINGS="searxng/settings.yml"

# Generate a real secret_key on first run.
if grep -q 'CHANGE_ME' "$SETTINGS"; then
  KEY="$(openssl rand -hex 32)"
  # portable in-place edit (GNU + BSD sed)
  sed -i.bak "s/CHANGE_ME/${KEY}/" "$SETTINGS" && rm -f "${SETTINGS}.bak"
  echo "→ generated server.secret_key"
fi

echo "→ pulling images"
docker compose pull

echo "→ starting stack"
docker compose up -d

echo
echo "Done. Once DNS + TLS settle, verify the JSON API the iOS app needs:"
echo "  curl -fsS 'https://search.searxly.app/search?q=test&format=json' | head -c 200; echo"
echo
echo "Then point the app at it: Settings ▸ Search instance → https://search.searxly.app"
echo "(or set SearchSettings.placeholderInstance to ship it as the default)."
