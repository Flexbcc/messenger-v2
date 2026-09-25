#!/usr/bin/env bash
# Generate OPERATOR_SECRET for local control panel (laptop.env).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/config/deploy/laptop.env"
EXAMPLE="${ROOT}/config/deploy/laptop.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE" "$ENV_FILE"
  echo "Created $ENV_FILE"
fi

SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")

if grep -q '^OPERATOR_SECRET=' "$ENV_FILE" 2>/dev/null; then
  tmp=$(mktemp)
  awk -F= -v s="$SECRET" 'BEGIN{OFS="="} $1=="OPERATOR_SECRET" {print "OPERATOR_SECRET",s; next} {print}' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
else
  echo "OPERATOR_SECRET=$SECRET" >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE" 2>/dev/null || true
echo "OPERATOR_SECRET обновлён в $ENV_FILE"
echo "Запуск панели: ./scripts/start-operator.sh"
echo "Сохраните ключ — он нужен только на вашем Mac для входа в панель."
