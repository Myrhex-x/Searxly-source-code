#!/bin/bash
#
# build-searxng-runtime.sh
#
# Assembles a relocatable, code-signable, notarizable arm64 Python + SearXNG runtime
# that Searxly bundles in place of Docker. Codifies the Phase 0 spike recipe.
#
# Output: build/searxng-runtime/python/   (interpreter + site-packages with SearXNG)
#   - read-only, signed; bundled into Searxly.app/Contents/Resources/searxng-runtime
#     at Xcode build time (wired up in a later phase). NEVER copy it to a writable
#     path at runtime — that breaks the signature / Gatekeeper.
#
# Usage:
#   ./scripts/build-searxng-runtime.sh            # build + self-test + sign (if a Developer ID cert is present)
#   SEARXLY_RUNTIME_SKIP_SIGN=1 ./scripts/...     # build + self-test only (fast iteration)
#   SEARXLY_RUNTIME_SKIP_TEST=1 ./scripts/...     # skip the serve-JSON self-test
#
# Apple Silicon only. Requires: curl, git, codesign.
#
set -euo pipefail

# ── Pinned versions (bump deliberately, in lockstep with SearxngRuntimeConfig.swift) ──
PY_VERSION="3.12.13"
PBS_RELEASE="20260610"                 # astral-sh/python-build-standalone release tag
SEARXNG_COMMIT="d456f3dd9"             # == upstream docker tag 2025.2.12-d456f3dd9
# Code-signing identity for the runtime. Override with SEARXLY_SIGN_IDENTITY; the default generic
# "Developer ID Application" prefix lets codesign resolve your single Developer ID cert. To skip
# signing entirely, export SEARXLY_RUNTIME_SKIP_SIGN=1.
SIGN_IDENTITY="${SEARXLY_SIGN_IDENTITY:-Developer ID Application}"

PBS_ASSET="cpython-${PY_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ASSET}"
SEARXNG_REPO="https://github.com/searxng/searxng"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$PROJECT_DIR/build/searxng-runtime-build"   # scratch (download cache + source clone)
OUT="$PROJECT_DIR/build/searxng-runtime"          # final runtime tree
RUNTIME="$OUT/python"
PY="$RUNTIME/bin/python3.12"

log() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "ERROR: this runtime is Apple Silicon (arm64) only; you are on $(uname -m)." >&2
  exit 1
fi

# ── 1. Relocatable CPython ────────────────────────────────────────────────────
log "Fetching relocatable CPython ${PY_VERSION} (python-build-standalone ${PBS_RELEASE})"
mkdir -p "$WORK"
if [[ ! -f "$WORK/$PBS_ASSET" ]]; then
  curl -fL --retry 3 -o "$WORK/$PBS_ASSET" "$PBS_URL"
else
  echo "  (using cached $PBS_ASSET)"
fi

log "Extracting interpreter into $RUNTIME"
rm -rf "$RUNTIME"
mkdir -p "$OUT"
# Archive contains a top-level python/ dir; extract it directly under $OUT.
tar -xzf "$WORK/$PBS_ASSET" -C "$OUT"
[[ -x "$PY" ]] || { echo "ERROR: expected interpreter not found at $PY" >&2; exit 1; }
echo "  interpreter: $("$PY" -V)"

# ── 2. SearXNG source pinned to the upstream commit we ship today ──────────────
# git can't fetch an abbreviated SHA as a ref, so resolve the full SHA and fetch
# that (shallow). Falls back to a full clone + checkout if the API is unavailable.
SRC="$WORK/searxng-src"
rm -rf "$SRC"
log "Resolving full commit SHA for ${SEARXNG_COMMIT}"
FULL_SHA="$(curl -fsSL "https://api.github.com/repos/searxng/searxng/commits/${SEARXNG_COMMIT}" \
  | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || true)"

if [[ -n "$FULL_SHA" ]]; then
  echo "  full SHA: $FULL_SHA"
  log "Fetching SearXNG source (shallow @ ${FULL_SHA})"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$SEARXNG_REPO"
  git -C "$SRC" fetch --depth 1 origin "$FULL_SHA"
  git -C "$SRC" checkout -q FETCH_HEAD
else
  echo "  (API lookup failed; falling back to full clone)"
  log "Cloning SearXNG and checking out ${SEARXNG_COMMIT}"
  git clone -q "$SEARXNG_REPO" "$SRC"
  git -C "$SRC" checkout -q "$SEARXNG_COMMIT"
fi

# ── 3. Install SearXNG + deps as prebuilt arm64 wheels (zero compilation) ──────
log "Installing dependencies (binary wheels only)"
"$PY" -m pip install --upgrade --quiet pip
"$PY" -m pip install --only-binary=:all: --quiet -r "$SRC/requirements.txt"
"$PY" -m pip install --quiet setuptools

log "Freezing version (so no .git is needed at runtime)"
# Must run inside the source tree where searx/ and .git live; writes searx/version_frozen.py.
( cd "$SRC" && "$PY" -m searx.version freeze )

log "Installing SearXNG itself"
"$PY" -m pip install --no-deps --no-build-isolation --quiet "$SRC"

SEARXNG_VERSION="$("$PY" -c 'import searx.version as v; print(v.VERSION_STRING)' 2>/dev/null || echo unknown)"
echo "  SearXNG version: $SEARXNG_VERSION"

# ── 4. Self-test: serve JSON as a plain subprocess ────────────────────────────
if [[ "${SEARXLY_RUNTIME_SKIP_TEST:-0}" != "1" ]]; then
  log "Self-test: serving SearXNG JSON"
  TEST_PORT=8899
  TEST_SETTINGS="$WORK/test-settings.yml"
  cat > "$TEST_SETTINGS" <<YAML
use_default_settings: true
server:
  secret_key: "selftest-$(openssl rand -hex 16)"
  bind_address: "127.0.0.1"
  port: ${TEST_PORT}
  limiter: false
search:
  formats:
    - html
    - json
YAML

  SEARXNG_SETTINGS_PATH="$TEST_SETTINGS" \
  SEARXNG_BIND_ADDRESS="127.0.0.1" \
  SEARXNG_PORT="$TEST_PORT" \
    "$PY" -m searx.webapp >"$WORK/selftest.log" 2>&1 &
  SERVER_PID=$!
  trap '[[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

  ok=""
  for _ in $(seq 1 40); do
    if curl -fs "http://127.0.0.1:${TEST_PORT}/search?q=test&format=json" -o "$WORK/selftest.json" 2>/dev/null; then
      ok=1; break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "ERROR: server exited early; log:" >&2; cat "$WORK/selftest.log" >&2; exit 1; }
    sleep 0.75
  done
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  trap - EXIT

  if [[ -z "$ok" ]]; then
    echo "ERROR: SearXNG did not serve JSON within timeout. Log:" >&2
    cat "$WORK/selftest.log" >&2
    exit 1
  fi
  bytes="$(wc -c < "$WORK/selftest.json" | tr -d ' ')"
  echo "  ✓ /search?format=json responded ($bytes bytes of JSON)"
fi

# ── 5. Codesign every Mach-O under Hardened Runtime ───────────────────────────
if [[ "${SEARXLY_RUNTIME_SKIP_SIGN:-0}" == "1" ]]; then
  log "Skipping code signing (SEARXLY_RUNTIME_SKIP_SIGN=1)"
elif ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  log "Skipping code signing — identity not found:"
  echo "  \"$SIGN_IDENTITY\""
  echo "  (build + test still valid; re-run on a machine with the cert to sign)"
else
  log "Code signing all Mach-O with Developer ID (Hardened Runtime + timestamp)"
  count=0
  # .so / .dylib first, then the interpreter executable last.
  while IFS= read -r -d '' f; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
    count=$((count + 1))
  done < <(find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' \) -print0)
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$PY"
  count=$((count + 1))
  echo "  signed $count Mach-O binaries"
  codesign --verify --strict "$PY" && echo "  ✓ interpreter signature verifies"
fi

log "Done"
echo "Runtime:         $RUNTIME"
echo "SearXNG version: $SEARXNG_VERSION"
echo "Launch (manual): SEARXNG_SETTINGS_PATH=<settings.yml> SEARXNG_BIND_ADDRESS=127.0.0.1 SEARXNG_PORT=8080 \\"
echo "                 \"$PY\" -m searx.webapp"
