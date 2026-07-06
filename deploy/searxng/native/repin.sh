#!/usr/bin/env bash
#
# Re-pin the native SearXNG to the exact version the Searxly web theme targets (2026.6.23 / e3713717f
# — the same version the macOS app bundles), reinstall, and apply the monochrome theme cleanly.
# Run as root. Pass the theme dir you scp'd (e.g. ~/searxly-theme).
#   usage: bash repin.sh /root/searxly-theme
#
set -euo pipefail
THEME="${1:?usage: bash repin.sh /path/to/custom}"
REF="e3713717f"
PIP=/opt/searxng/venv/bin/pip
PY=/opt/searxng/venv/bin/python

[ -d "$THEME/templates/simple" ] || { echo "ERROR: no templates/simple under $THEME"; exit 1; }

echo "==> [1/5] stopping searxng"
systemctl stop searxng || true

echo "==> [2/5] cloning SearXNG at $REF (matches the macOS app + the theme)"
rm -rf /opt/searxng/searxng-src
sudo -u searxng git clone -q https://github.com/searxng/searxng /opt/searxng/searxng-src
sudo -u searxng git -C /opt/searxng/searxng-src checkout -q "$REF"

echo "==> [3/5] reinstalling (a few minutes)"
sudo -u searxng "$PIP" install -q -r /opt/searxng/searxng-src/requirements.txt
sudo -u searxng bash -c "cd /opt/searxng/searxng-src && $PY -m searx.version freeze"
sudo -u searxng "$PIP" install -q --no-deps --no-build-isolation /opt/searxng/searxng-src

echo "==> [4/5] applying the Searxly monochrome theme"
SRC=/opt/searxng/searxng-src/searx
cp -a "$THEME/templates/simple/." "$SRC/templates/simple/"
mkdir -p "$SRC/static/themes/simple"
cp -a "$THEME/static/themes/simple/searxly.css" "$SRC/static/themes/simple/searxly.css"
chown -R searxng:searxng "$SRC/templates/simple" "$SRC/static/themes/simple"

echo "==> [5/5] starting + verifying"
systemctl start searxng
sleep 8
if curl -fsS 'http://127.0.0.1:8080/search?q=test&format=json' | head -c 80 | grep -q '{'; then
  echo "✅ Up and returning JSON. Open https://search.searxly.app in a browser — should be on-brand now."
else
  echo "⚠️  Not responding yet — check: journalctl -u searxng -n 60 --no-pager"
fi
