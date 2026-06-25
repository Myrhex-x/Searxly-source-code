#!/bin/bash
#
# fetch-tor-runtime.sh
#
# Fetches a relocatable, code-signable `tor` client (+ geoip data) that Searxly bundles to reach
# `.onion` hidden services. Mirrors build-searxng-runtime.sh: the output is a read-only, signed tree
# that the "Bundle Tor runtime" Xcode build phase rsyncs into
# Searxly.app/Contents/Resources/tor-runtime at build time.
#
# Source: the Tor Project's official "tor-expert-bundle" (the same tor binary Tor Browser ships).
#
# Output: build/tor-runtime/
#     tor        - the tor client binary (signed, Hardened Runtime)
#     geoip      - IPv4 GeoIP database
#     geoip6     - IPv6 GeoIP database
#
# Usage:
#   ./scripts/fetch-tor-runtime.sh                     # download + sign (if a Developer ID cert is present)
#   TOR_VERSION=14.0.1 ./scripts/fetch-tor-runtime.sh  # pin a specific Tor Browser version
#   SEARXLY_RUNTIME_SKIP_SIGN=1 ./scripts/...          # download only (fast iteration)
#
# Requires: curl, tar, codesign, shasum. Apple Silicon or Intel (arch auto-detected).
#
set -euo pipefail

# ── Pinned version (bump deliberately, in lockstep with TorRuntimeConfig.swift `bundledVersion`) ──
# Latest stable verified 2026-06-25 from the official archive. Check for newer at
# https://archive.torproject.org/tor-package-archive/torbrowser/ (use a STABLE version, not an "a" alpha).
TOR_VERSION="${TOR_VERSION:-15.0.16}"

# Code-signing identity for the binary. Override with SEARXLY_SIGN_IDENTITY; the default generic
# "Developer ID Application" prefix lets codesign resolve your single Developer ID cert. Skip with
# SEARXLY_RUNTIME_SKIP_SIGN=1.
SIGN_IDENTITY="${SEARXLY_SIGN_IDENTITY:-Developer ID Application}"

case "$(uname -m)" in
  arm64) TOR_ARCH="aarch64" ;;
  x86_64) TOR_ARCH="x86_64" ;;
  *) echo "error: unsupported arch $(uname -m)"; exit 1 ;;
esac

ASSET="tor-expert-bundle-macos-${TOR_ARCH}-${TOR_VERSION}.tar.gz"
URL="https://archive.torproject.org/tor-package-archive/torbrowser/${TOR_VERSION}/${ASSET}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$PROJECT_DIR/build/tor-runtime-build"   # scratch (download + extract)
OUT="$PROJECT_DIR/build/tor-runtime"          # final runtime tree (bundled by Xcode)

echo "▶ Fetching Tor expert bundle ${TOR_VERSION} (${TOR_ARCH})"
rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"

echo "  $URL"
curl -fL --retry 3 -o "$WORK/$ASSET" "$URL"
tar -xzf "$WORK/$ASSET" -C "$WORK"

# The expert bundle layout has historically been tor/tor + data/geoip[6]. Locate them defensively
# so a future layout change is easy to spot rather than silently producing an empty runtime.
TOR_BIN="$(find "$WORK" -type f -name tor -perm -u+x | head -1)"
GEOIP="$(find "$WORK" -type f -name geoip | head -1)"
GEOIP6="$(find "$WORK" -type f -name geoip6 | head -1)"

[ -n "$TOR_BIN" ] || { echo "error: tor binary not found in bundle"; exit 1; }

cp "$TOR_BIN" "$OUT/tor"
chmod +x "$OUT/tor"
[ -n "$GEOIP" ] && cp "$GEOIP" "$OUT/geoip" || echo "  note: geoip not found (tor still works; path selection only)"
[ -n "$GEOIP6" ] && cp "$GEOIP6" "$OUT/geoip6" || echo "  note: geoip6 not found"

# Copy any sibling dylibs the binary may need (most expert-bundle builds are self-contained).
find "$(dirname "$TOR_BIN")" -maxdepth 1 -name '*.dylib' -exec cp {} "$OUT/" \; 2>/dev/null || true

if [ "${SEARXLY_RUNTIME_SKIP_SIGN:-0}" != "1" ]; then
  echo "▶ Code-signing (Hardened Runtime): $SIGN_IDENTITY"
  for f in "$OUT"/*.dylib; do [ -e "$f" ] && codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$f"; done
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$OUT/tor"
  codesign -dv "$OUT/tor" 2>&1 | sed 's/^/   /' || true
else
  echo "▶ Skipping code-signing (SEARXLY_RUNTIME_SKIP_SIGN=1) — onion support will fail Gatekeeper until signed."
fi

rm -rf "$WORK"
echo "✅ Tor runtime ready at: $OUT"
echo "   Next: in Xcode, add build/tor-runtime to the Searxly target (Add Files → Create folder"
echo "   references), or rely on the 'Bundle Tor runtime' build phase to copy it. Then update"
echo "   TorRuntimeConfig.bundledVersion to ${TOR_VERSION} and rebuild."
