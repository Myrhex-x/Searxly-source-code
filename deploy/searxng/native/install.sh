#!/usr/bin/env bash
#
# Native SearXNG install for Debian/Ubuntu — NO Docker. Run as root on the gateway box.
# Installs SearXNG as a systemd service bound to 127.0.0.1:8080 (localhost only — your existing
# Caddy proxies to it). Idempotent: safe to re-run to update.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> [1/6] system dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-dev python3-venv python3-pip git build-essential \
  libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev curl openssl

echo "==> [2/6] searxng user + dirs"
id -u searxng >/dev/null 2>&1 || useradd --system --home-dir /opt/searxng --shell /usr/sbin/nologin searxng
mkdir -p /etc/searxng
install -d -o searxng -g searxng /opt/searxng

echo "==> [3/6] clone SearXNG"
if [ -d /opt/searxng/searxng-src/.git ]; then
  sudo -u searxng git -C /opt/searxng/searxng-src pull --ff-only || true
else
  sudo -u searxng git clone --depth 1 https://github.com/searxng/searxng /opt/searxng/searxng-src
fi

echo "==> [4/6] python venv + install (this is the slow step — a few minutes)"
[ -d /opt/searxng/venv ] || sudo -u searxng python3 -m venv /opt/searxng/venv
sudo -u searxng /opt/searxng/venv/bin/pip install -q --upgrade pip setuptools wheel pyyaml
# SearXNG's build imports its own package (which needs msgspec etc.), so install the runtime
# requirements FIRST, freeze the version, then install searxng without build isolation. This is
# exactly what the macOS build does — a plain `pip install -e .` fails with ModuleNotFoundError: msgspec.
sudo -u searxng /opt/searxng/venv/bin/pip install -q -r /opt/searxng/searxng-src/requirements.txt
sudo -u searxng bash -c 'cd /opt/searxng/searxng-src && /opt/searxng/venv/bin/python -m searx.version freeze'
sudo -u searxng /opt/searxng/venv/bin/pip install -q --no-deps --no-build-isolation /opt/searxng/searxng-src

echo "==> [5/6] settings.yml (+ generated secret_key) and systemd service"
if [ ! -f /etc/searxng/settings.yml ]; then
  install -m 640 -o searxng -g searxng "$HERE/settings.yml" /etc/searxng/settings.yml
  sed -i "s/CHANGE_ME/$(openssl rand -hex 32)/" /etc/searxng/settings.yml
  echo "    wrote /etc/searxng/settings.yml with a fresh secret_key"
else
  echo "    /etc/searxng/settings.yml exists — leaving it as-is"
fi
install -m 644 "$HERE/searxng.service" /etc/systemd/system/searxng.service
systemctl daemon-reload
systemctl enable --now searxng

echo "==> [6/6] verifying the JSON API"
sleep 8
if curl -fsS 'http://127.0.0.1:8080/search?q=test&format=json' 2>/dev/null | head -c 80 | grep -q '{'; then
  echo
  echo "✅ SearXNG is running on 127.0.0.1:8080 and returning JSON."
  echo "   Next: wire it into Caddy (see caddy-site-snippet.txt), then point the app at it."
else
  echo
  echo "⚠️  Not responding with JSON yet. Check the logs:"
  echo "      journalctl -u searxng -n 60 --no-pager"
fi
