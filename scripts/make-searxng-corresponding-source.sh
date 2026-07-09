#!/usr/bin/env bash
#
# make-searxng-corresponding-source.sh
#
# Assembles the AGPL "Corresponding Source" archive for the SearXNG that Searxly
# bundles/serves: the pinned upstream engine source + Searxly's modifications
# (the LocalSearxng/ theme & config overlay) + the AGPL license and a manifest.
#
# Publish the resulting tarball wherever your written offer points (and next to
# any hosted instance such as search.searxly.app, for AGPL §13). Run once per
# release whose bundled SearXNG version changes.
#
# Usage:
#   scripts/make-searxng-corresponding-source.sh [output_dir]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/dist}"

# Pinned SearXNG version actually shipped (keep in sync with the bundled runtime).
SEARXNG_VERSION="2026.6.23+e371371"
SEARXNG_UPSTREAM="https://github.com/searxng/searxng"

# Preferred source of the exact engine tree (produced by build-searxng-runtime.sh).
UPSTREAM_SRC="$REPO_ROOT/build/searxng-runtime-build/searxng-src"

STAGE="$(mktemp -d)"
BUNDLE="searxng-corresponding-source-${SEARXNG_VERSION//+/_}"
DEST="$STAGE/$BUNDLE"
mkdir -p "$DEST"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging Corresponding Source for SearXNG $SEARXNG_VERSION"

# 1) Upstream engine source (pinned).
if [ -d "$UPSTREAM_SRC" ]; then
  echo "    - upstream engine source: $UPSTREAM_SRC"
  mkdir -p "$DEST/searxng-upstream"
  # Copy the source tree, excluding VCS and build cruft.
  rsync -a --exclude '.git' --exclude '__pycache__' --exclude '*.pyc' \
        "$UPSTREAM_SRC/" "$DEST/searxng-upstream/"
else
  echo "    ! upstream source tree not found at $UPSTREAM_SRC"
  echo "      Run scripts/build-searxng-runtime.sh first, or fetch the pinned tag:"
  echo "      git clone $SEARXNG_UPSTREAM && cd searxng && git checkout <tag for $SEARXNG_VERSION>"
  cat > "$DEST/UPSTREAM-SOURCE.txt" <<EOF
The unmodified SearXNG engine for this release is version $SEARXNG_VERSION.
Obtain it from $SEARXNG_UPSTREAM (check out the tag/commit matching
$SEARXNG_VERSION). This archive contains Searxly's modifications; combine them
with that upstream tree for the complete Corresponding Source.
EOF
fi

# 2) Searxly's AGPL modifications (theme + config overlay).
echo "    - Searxly modifications: LocalSearxng/"
mkdir -p "$DEST/searxly-modifications"
rsync -a --exclude '.DS_Store' \
      "$REPO_ROOT/LocalSearxng/" "$DEST/searxly-modifications/LocalSearxng/"

# 3) License + provenance.
cp "$REPO_ROOT/LocalSearxng/LICENSE" "$DEST/LICENSE.AGPL-3.0" 2>/dev/null || true
GIT_REV="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
cat > "$DEST/README.txt" <<EOF
Corresponding Source — SearXNG as distributed by Searxly
========================================================

SearXNG version : $SEARXNG_VERSION
Upstream        : $SEARXNG_UPSTREAM
License         : AGPL-3.0-or-later (see LICENSE.AGPL-3.0)
Searxly rev     : $GIT_REV
Generated       : $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Contents:
  searxng-upstream/       Unmodified SearXNG engine source, pinned to the version above.
                          (If absent, see UPSTREAM-SOURCE.txt for how to obtain it.)
  searxly-modifications/  Searxly's AGPL-licensed theme and configuration overlay
                          (LocalSearxng/), which override/extend the upstream tree.

Together these constitute the Complete Corresponding Source for the SearXNG that
Searxly bundles and/or serves. The Searxly application code (Swift/WebKit) is a
separate work under the PolyForm Noncommercial License and is not part of this
archive.
EOF

# 4) Tarball.
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$BUNDLE.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" "$BUNDLE"

echo "==> Wrote $TARBALL"
echo "    Publish this at your written-offer URL and alongside any hosted instance."
