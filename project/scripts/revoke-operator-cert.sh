#!/usr/bin/env bash
###############################################################################
# revoke-operator-cert.sh
#
# Отзывает доступ оператора — например, когда потеряно устройство.
#
# Убирает запись из реестра и перегенерирует allowlist для nginx.
# Остальные сертификаты продолжают работать, CA перевыпускать не нужно.
#
# Использование:
#   bash scripts/revoke-operator-cert.sh alex-laptop
#   bash scripts/revoke-operator-cert.sh --list
###############################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${ROOT}/config/mtls"
REGISTRY="${DIR}/operators.tsv"
OPERATORS="${DIR}/operators"
NGINX_ALLOWLIST="${ROOT}/config/nginx/operators-allowlist.conf"

regenerate_allowlist() {
  {
    echo "# Автогенерация: scripts/generate-operator-cert.sh"
    echo "# Не редактируйте вручную — правьте operators.tsv и перезапустите скрипт."
    echo "#"
    echo "# Отзыв доступа: bash scripts/revoke-operator-cert.sh <имя>"
    echo ""
    echo "map \$ssl_client_fingerprint \$operator_allowed {"
    echo "    default 0;"
    while IFS=$'\t' read -r n s1 s256 exp; do
      [[ "$n" == \#* || -z "$n" ]] && continue
      printf '    %s 1;  # %s (до %s)\n' "$s1" "$n" "$exp"
    done < "$REGISTRY"
    echo "}"
  } > "$NGINX_ALLOWLIST"
}

if [[ ! -f "$REGISTRY" ]]; then
  echo "✗ Реестр операторов не найден: $REGISTRY"
  echo "  Ни одного сертификата ещё не выпущено."
  exit 1
fi

# ── Список ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list" || -z "${1:-}" ]]; then
  echo "Действующие сертификаты операторов:"
  echo ""
  printf "  %-20s %-28s %s\n" "ИМЯ" "ДЕЙСТВУЕТ ДО" "SHA-1"
  printf "  %-20s %-28s %s\n" "───" "────────────" "─────"
  while IFS=$'\t' read -r n s1 s256 exp; do
    [[ "$n" == \#* || -z "$n" ]] && continue
    printf "  %-20s %-28s %s\n" "$n" "$exp" "${s1:0:16}…"
  done < "$REGISTRY"
  echo ""
  if [[ -z "${1:-}" ]]; then
    echo "Отозвать:  bash scripts/revoke-operator-cert.sh <имя>"
  fi
  exit 0
fi

NAME="$1"

# ── Проверка что такой есть ─────────────────────────────────────────────────
if ! awk -F'\t' -v n="$NAME" '!/^#/ && $1 == n {found=1} END {exit !found}' "$REGISTRY"; then
  echo "✗ Оператор «${NAME}» не найден в реестре."
  echo ""
  echo "Список: bash scripts/revoke-operator-cert.sh --list"
  exit 1
fi

FP="$(awk -F'\t' -v n="$NAME" '!/^#/ && $1 == n {print $3}' "$REGISTRY")"

cat <<EOF

⚠️  Отзыв доступа оператора «${NAME}»

    SHA-256: ${FP}

    После отзыва этот сертификат перестанет пускать на ноды.
    Действие обратимо только перевыпуском сертификата.

EOF

read -p "Продолжить? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Отменено."
  exit 0
fi

# ── Убираем из реестра ──────────────────────────────────────────────────────
awk -F'\t' -v n="$NAME" '/^#/ || $1 != n' "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

# ── Архивируем сертификат, ключ удаляем ─────────────────────────────────────
REVOKED="${DIR}/revoked"
mkdir -p "$REVOKED"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "${OPERATORS}/${NAME}.crt" ]]; then
  mv "${OPERATORS}/${NAME}.crt" "${REVOKED}/${NAME}-${STAMP}.crt"
fi
# Приватный ключ больше не нужен никому — удаляем, а не архивируем
rm -f "${OPERATORS}/${NAME}.key"

regenerate_allowlist

REMAINING="$(awk -F'\t' '!/^#/ && NF' "$REGISTRY" | wc -l | tr -d ' ')"

cat <<EOF

✓ Доступ оператора «${NAME}» отозван.

  Осталось действующих сертификатов: ${REMAINING}
  Отозванный сертификат: ${REVOKED}/${NAME}-${STAMP}.crt
  Приватный ключ удалён.

────────────────────────────────────────────────────────────────
  Отзыв вступит в силу после обновления нод
────────────────────────────────────────────────────────────────

  Пока шлюзы не перезагружены, старый сертификат ПРОДОЛЖАЕТ работать.
  Разложите новый allowlist и перезагрузите nginx на каждой ноде:

    scp config/nginx/operators-allowlist.conf  node:/path/config/nginx/
    ssh node 'docker compose exec nginx-operator nginx -s reload'

  Локально (msng-test):

    docker compose -p msng exec msng-operator-gw nginx -s reload

EOF
