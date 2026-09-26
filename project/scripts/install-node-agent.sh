#!/usr/bin/env bash
# Install the restricted OUO host agent used for signed owner actions.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="${OWNER_AGENT_DIR:-$PROJECT_DIR/data/owner-agent}"
ENV_FILE="${OWNER_AGENT_ENV:-/etc/ouo-node-agent.env}"
UNIT_FILE="/etc/systemd/system/ouo-node-agent.service"

install -d -m 0700 "$AGENT_DIR" "$AGENT_DIR/requests" "$AGENT_DIR/results" "$AGENT_DIR/rejected"
if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOF
OWNER_AGENT_SECRET=$(openssl rand -hex 32)
# Signed updates stay disabled until these root-only values and
# /var/lib/ouo-update/metadata/root.json are provisioned.
# OUO_UPDATE_METADATA_URL=https://updates.example/metadata
# OUO_UPDATE_TARGETS_URL=https://updates.example/targets
# OUO_UPDATE_TARGET=ouo-node.tar.gz
# OUO_UPDATE_NODE_ID=<node-id>
# OUO_UPDATE_CURRENT_PROTOCOL=1
EOF
fi
chmod 0600 "$ENV_FILE"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OUO restricted node owner action agent
Requires=docker.service
After=docker.service

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $PROJECT_DIR/scripts/ouo-node-agent.py --spool $AGENT_DIR --install-dir $PROJECT_DIR
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$AGENT_DIR $PROJECT_DIR/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ouo-node-agent.service
echo "OUO node agent installed. Copy OWNER_AGENT_SECRET from $ENV_FILE into the node .env."
