#!/usr/bin/env bash
# Full HTTPS deploy: cert + nginx + PWA rebuild + landing + verify.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MSG="${ROOT}/../frontend/app"
[[ -d "$MSG" ]] || MSG="${ROOT}/client/messenger_app"
LANDING="${ROOT}/landing"
MAIN="${MAIN_HOST:-root@194.67.92.147}"
IP="${MAIN_IP:-194.67.92.147}"
SSH_KEY="${LAPTOP_SSH_KEY:-$HOME/.ssh/messenger_ops}"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
RSYNC_E=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

log() { echo; echo "==> $*"; }

# ── 1. Manifest ───────────────────────────────────────────────────────────────
if [[ -x "$ROOT/scripts/generate-release-manifest.sh" ]]; then
  LANDING_URL="https://${IP}" BUILD_STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$ROOT/scripts/generate-release-manifest.sh"
  python3 - <<PY
import json
from pathlib import Path
p = Path("$ROOT/releases/clients/manifest.json")
d = json.loads(p.read_text())
d["landing_url"] = "https://${IP}"
for prod in d.get("products", {}).values():
    for plat, cfg in prod.get("platforms", {}).items():
        if plat == "web":
            cfg["update_kind"] = "reload"
        if cfg.get("download_url") and "7357" in cfg["download_url"]:
            cfg["download_url"] = cfg["download_url"].replace("http://${IP}:7357", "https://${IP}")
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
fi

# ── 2. Build PWA (HTTPS same-origin URLs) ─────────────────────────────────────
log "Build PWA for HTTPS"
export HOME_NODE_URL="https://${IP}/home"
export MEDIA_NODE_URL="https://${IP}/media"
export DISCOVERY_NODE_URL="https://${IP}/discovery"
export GATEWAY_NODE_URL="https://${IP}"
export PWA_BASE_HREF="/app/"
cd "$MSG"
"${FLUTTER:-/Users/apple/flutter/bin/flutter}" pub get
"$MSG/scripts/build-web-pwa.sh"

# ── 3. Assemble site ──────────────────────────────────────────────────────────
log "Assemble site bundle"
rm -rf "$LANDING/app"
mkdir -p "$LANDING/app" "$LANDING/releases/clients"
cp -R "$MSG/build/web/." "$LANDING/app/"
cp "$ROOT/releases/clients/manifest.json" "$LANDING/releases/clients/"
rm -rf "$LANDING/downloads/messenger-web"
DIST="${ROOT}/../dist/clients"
STAMP="$(ls -1 "$DIST" 2>/dev/null | sort | tail -1 || true)"
if [[ -n "$STAMP" && -d "$DIST/$STAMP" ]]; then
  mkdir -p "$LANDING/downloads"
  for f in Messenger-macos-arm64.zip StorageApp-macos-arm64.zip; do
    [[ -f "$DIST/$STAMP/$f" ]] && cp -f "$DIST/$STAMP/$f" "$LANDING/downloads/"
  done
  (cd "$LANDING/downloads" && rm -f Messenger-web.zip && ditto -c -k --sequesterRsrc ../app Messenger-web.zip)
fi

# ── 4. Upload site + nginx config ─────────────────────────────────────────────
log "Upload to MAIN"
"${SSH[@]}" "$MAIN" "mkdir -p /var/www/messenger-site /etc/ssl/messenger"
rsync -az --delete -e "${RSYNC_E[*]}" \
  --exclude=downloads/messenger-web \
  "$LANDING/" "$MAIN:/var/www/messenger-site/"
rsync -az -e "${RSYNC_E[*]}" \
  "$ROOT/deploy/nginx-messenger-site.conf" "$MAIN:/etc/nginx/sites-available/messenger-site.conf"
"${SSH[@]}" "$MAIN" "chown -R www-data:www-data /var/www/messenger-site && chmod -R a+rX /var/www/messenger-site"

# ── 5. TLS cert + nginx on server ─────────────────────────────────────────────
log "TLS + nginx"
"${SSH[@]}" "$MAIN" bash -s <<'REMOTE'
set -euo pipefail
IP="194.67.92.147"
if [[ ! -f /etc/ssl/messenger/fullchain.pem ]]; then
  apt-get update -qq
  apt-get install -y -qq nginx openssl
  mkdir -p /etc/ssl/messenger
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/ssl/messenger/privkey.pem \
    -out /etc/ssl/messenger/fullchain.pem \
    -days 825 \
    -subj "/CN=${IP}" \
    -addext "subjectAltName=IP:${IP},DNS:localhost,IP:127.0.0.1"
fi
ln -sf /etc/nginx/sites-available/messenger-site.conf /etc/nginx/sites-enabled/messenger-site.conf
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl enable nginx
systemctl reload nginx
pkill -f "http.server 7357" 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
REMOTE

# ── 6. Verify ─────────────────────────────────────────────────────────────────
log "Verify"
"${SSH[@]}" "$MAIN" bash -s <<'VERIFY'
set -e
check() {
  local url="$1"
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' "$url")
  echo "$code $url"
  [[ "$code" == "200" || "$code" == "301" ]]
}
check https://127.0.0.1/
check https://127.0.0.1/app/
check https://127.0.0.1/app/manifest.json
check https://127.0.0.1/app/flutter_bootstrap.js
check https://127.0.0.1/releases/clients/manifest.json
check https://127.0.0.1/home/health
check https://127.0.0.1/health
grep -q 'base href="/app/"' /var/www/messenger-site/app/index.html
echo OK base-href
VERIFY

echo
echo "════════════════════════════════════════════"
echo "  Landing:  https://${IP}/"
echo "  PWA:      https://${IP}/app/"
echo "  (самоподписанный cert — один раз «Продолжить» в браузере)"
echo "════════════════════════════════════════════"
