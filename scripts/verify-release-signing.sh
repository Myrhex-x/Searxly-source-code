#!/bin/bash
#
# verify-release-signing.sh <path-to-.app> [.app ...]
#
# Release gate that catches the class of bug that shipped in 1.0 / Maximum 1.2:
# an app signed with a DEVICE-LOCKED development provisioning profile launches
# only on the build Mac and fails everywhere else with
# "The application can't be opened." (AMFI -10810).
#
# spctl / codesign / notarization all PASS on such a build (they don't inspect
# the profile's device list), so this check exists specifically to look at it.
#
# Run it on every exported app BEFORE building the DMG / notarizing:
#   ./scripts/verify-release-signing.sh path/to/Searxly.app
# Exit code 0 = safe to ship, non-zero = do NOT ship.

set -uo pipefail

fail_total=0

check_app () {
  local APP="$1"
  echo "── $APP"
  if [ ! -d "$APP" ]; then echo "   ❌ not an .app bundle"; fail_total=1; return; fi

  local fail=0
  local PROF="$APP/Contents/embedded.provisionprofile"
  if [ -f "$PROF" ]; then
    local P=$(mktemp)
    security cms -D -i "$PROF" > "$P" 2>/dev/null
    local ALL NAME NDEV
    ALL=$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$P" 2>/dev/null || true)
    NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$P" 2>/dev/null || echo '?')
    if [ "$ALL" = "true" ]; then
      echo "   ✅ profile provisions ALL devices — \"$NAME\""
    else
      NDEV=$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$P" 2>/dev/null | grep -cE '[0-9A-Fa-f]{8}' || echo 0)
      echo "   ❌ DEVICE-LOCKED profile — \"$NAME\" (ProvisionsAllDevices!=true, ${NDEV} device[s])"
      echo "      → will ONLY launch on the listed device(s). Re-sign with the Developer ID (\"…Direct…\") profile."
      fail=1
    fi
    rm -f "$P"
  else
    echo "   ✅ no embedded provisioning profile (runs everywhere)"
  fi

  # Profile must include the CURRENT signing cert, or AMFI SIGKILLs at launch
  # (passes spctl/codesign/notarization — this is exactly what broke base 1.0).
  if [ -f "$PROF" ]; then
    local CDIR; CDIR=$(mktemp -d)
    codesign -d --extract-certificates="$CDIR/c" "$APP" >/dev/null 2>&1
    if [ -f "${CDIR}/c0" ]; then
      local LEAF; LEAF=$(shasum -a 1 "${CDIR}/c0" | awk '{print toupper($1)}')
      if security cms -D -i "$PROF" 2>/dev/null | python3 -c '
import sys,plistlib,hashlib
leaf=sys.argv[1]
d=plistlib.loads(sys.stdin.buffer.read())
hs=[hashlib.sha1(bytes(c)).hexdigest().upper() for c in d.get("DeveloperCertificates",[])]
sys.exit(0 if leaf in hs else 1)' "$LEAF" 2>/dev/null; then
        echo "   ✅ signing cert is in the profile's cert list"
      else
        echo "   ❌ signing cert NOT in the embedded profile → AMFI will kill it at launch"
        echo "      → regenerate the profile: xcodebuild -exportArchive … -allowProvisioningUpdates"
        fail=1
      fi
    fi
    rm -rf "$CDIR"
  fi

  # Development-signed builds carry get-task-allow (also rejected by notarization).
  if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
    echo "   ❌ get-task-allow present — development-signed, not for distribution"
    fail=1
  fi

  # Notarization / Gatekeeper (advisory — run again after notarize+staple).
  if spctl -a -t exec -vv "$APP" 2>&1 | grep -qi 'accepted'; then
    echo "   ✅ Gatekeeper accepts (notarized + stapled)"
  else
    echo "   ⚠️  Gatekeeper not accepting yet — notarize + staple before shipping"
  fi

  [ "$fail" = 0 ] || fail_total=1
}

if [ $# -eq 0 ]; then
  echo "usage: $0 /path/to/App.app [more.app ...]"
  exit 2
fi

for a in "$@"; do check_app "$a"; done

echo ""
if [ "$fail_total" = 0 ]; then
  echo "PASS — safe to ship."
else
  echo "FAIL — do NOT ship. Fix the ❌ items above."
  exit 1
fi
