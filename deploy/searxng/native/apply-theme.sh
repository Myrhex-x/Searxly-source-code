#!/usr/bin/env bash
#
# Apply the Searxly monochrome web theme to the native SearXNG install. Run as root on the server.
#   usage: bash apply-theme.sh /path/to/custom        (the LocalSearxng/custom directory)
#
# SAFE + REVERTIBLE: backs up the originals first. The JSON API (and therefore the iOS app) is
# unaffected no matter what — this only restyles the HTML web UI at search.searxly.app.
#
set -euo pipefail
THEME="${1:?usage: bash apply-theme.sh /path/to/custom}"
SRC="/opt/searxng/searxng-src/searx"
TPL="$SRC/templates/simple"
STATIC="$SRC/static/themes/simple"

[ -d "$THEME/templates/simple" ] || { echo "ERROR: no templates/simple under $THEME"; exit 1; }
[ -d "$TPL" ]                     || { echo "ERROR: SearXNG templates not found at $TPL"; exit 1; }

BK="/opt/searxng/theme-backup-$(date +%s)"
echo "==> backing up current templates to $BK"
mkdir -p "$BK/templates-simple"
cp -a "$TPL/." "$BK/templates-simple/"

echo "==> applying Searxly monochrome theme"
cp -a "$THEME/templates/simple/." "$TPL/"
mkdir -p "$STATIC"
cp -a "$THEME/static/themes/simple/searxly.css" "$STATIC/searxly.css"
chown -R searxng:searxng "$TPL" "$STATIC"

echo "==> restarting searxng"
systemctl restart searxng
sleep 5

echo
echo "✅ Applied. Open https://search.searxly.app in a browser to check the look."
echo
echo "   If anything renders wrong, revert instantly with:"
echo "     cp -a $BK/templates-simple/. $TPL/ && systemctl restart searxng"
