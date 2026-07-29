#!/usr/bin/env bash
# УСТАРЕЛО — заменено пультом в operator-console/
#
#     cd operator-console && ./up.sh
#
# Новый пульт умеет всё то же самое плюс телеметрию федерации,
# управление членством нод и журнал аудита через mTLS.
set -euo pipefail

cat >&2 <<'EOF'

  Этот скрипт устарел — используйте пульт из operator-console/

      cd operator-console
      cp .env.example .env && nano .env
      ./up.sh

  Оба занимают порт 9300, одновременно не запускаются.

EOF
exit 1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f config/deploy/laptop.env ]]; then
  echo "Copy config/deploy/laptop.env.example → laptop.env and set GITEA_PASSWORD + hosts." >&2
  exit 1
fi

chmod +x scripts/operator-console.py scripts/setup-operator-secret.sh

if ! grep -q '^OPERATOR_SECRET=.\+' config/deploy/laptop.env 2>/dev/null; then
  echo "Подсказка: ./scripts/setup-operator-secret.sh — защита панели ключом" >&2
fi

exec python3 scripts/operator-console.py
