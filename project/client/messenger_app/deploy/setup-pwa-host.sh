#!/usr/bin/env bash
# Run once ON MAIN SERVER (194.67.92.147) as root:
#   curl -sL ... | bash
# Or: ssh root@194.67.92.147 'bash -s' < deploy/setup-pwa-host.sh
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/root/messenger-pwa}"
PWA_PORT="${PWA_PORT:-7357}"
SERVICE_NAME="${SERVICE_NAME:-messenger-pwa}"

mkdir -p "$REMOTE_DIR"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Messenger PWA static files
After=network.target

[Service]
Type=simple
WorkingDirectory=${REMOTE_DIR}
ExecStart=/usr/bin/python3 -m http.server ${PWA_PORT} --bind 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PWA_PORT}/tcp" || true
fi

echo "OK: systemd ${SERVICE_NAME} on port ${PWA_PORT}"
systemctl --no-pager status "${SERVICE_NAME}" || true
