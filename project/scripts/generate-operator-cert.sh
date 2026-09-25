#!/usr/bin/env bash
###############################################################################
# generate-operator-cert.sh
#
# Выпускает клиентский сертификат ОПЕРАТОРА — ключ доступа к пульту управления.
#
# Этим сертификатом пульт (operator-console) авторизуется на нодах.
# Без него TLS-хендшейк обрывается: админ-порт ноды выглядит мёртвым
# даже для того, кто знает, что он там есть.
#
# Использование:
#   bash scripts/generate-operator-cert.sh alex-macbook
#   bash scripts/generate-operator-cert.sh alex-phone --days 90
#
# Сертификат — это полный доступ к управлению федерацией.
# Выпускай отдельный на каждое устройство: скомпрометированное
# устройство отзывается без перевыпуска остальных.
###############################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${ROOT}/config/mtls"
OPERATORS="${DIR}/operators"
FP_SCRIPT="${ROOT}/scripts/cert-fingerprint.sh"

NAME="${1:-}"
DAYS=365

# --days N
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  cat <<'USAGE'
Укажите имя устройства оператора.

  bash scripts/generate-operator-cert.sh <имя> [--days N]

Примеры:
  bash scripts/generate-operator-cert.sh alex-macbook
  bash scripts/generate-operator-cert.sh alex-laptop --days 90

Имя попадёт в CN сертификата и в журнал аудита — по нему будет видно,
с какого устройства выполнено действие.
USAGE
  exit 1
fi

# Только безопасные символы: имя идёт в CN и в имя файла
if [[ ! "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "✗ Имя может содержать только латиницу, цифры, точку, дефис и подчёркивание"
  exit 1
fi

if [[ ! -f "${DIR}/ca.crt" ]]; then
  echo "✗ CA не найден: ${DIR}/ca.crt"
  echo "  Сначала выполните: bash scripts/generate-mtls-certs.sh"
  exit 1
fi

mkdir -p "$OPERATORS"
chmod 700 "$OPERATORS"

CRT="${OPERATORS}/${NAME}.crt"
KEY="${OPERATORS}/${NAME}.key"

if [[ -f "$CRT" && "${FORCE:-0}" != "1" ]]; then
  echo "✗ Сертификат уже существует: $CRT"
  echo "  Перевыпустить: FORCE=1 bash scripts/generate-operator-cert.sh $NAME"
  exit 1
fi

echo "→ Выпускаю сертификат оператора «${NAME}» на ${DAYS} дней..."

# CN=operator-<name> — префикс operator- отличает пульт от нод и клиентов.
# Ноды проверяют этот префикс, прежде чем пустить в админ-API.
openssl genrsa -out "$KEY" 4096 2>/dev/null
openssl req -new -key "$KEY" \
  -subj "/CN=operator-${NAME}/OU=operator" \
  -out "${OPERATORS}/${NAME}.csr" 2>/dev/null

# extendedKeyUsage=clientAuth — сертификат годится только для клиентской
# аутентификации. Даже утечка не позволит поднять с ним сервер-двойник.
openssl x509 -req \
  -in "${OPERATORS}/${NAME}.csr" \
  -CA "${DIR}/ca.crt" -CAkey "${DIR}/ca.key" -CAcreateserial \
  -out "$CRT" -days "$DAYS" -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\nbasicConstraints=critical,CA:FALSE\n") \
  2>/dev/null

rm -f "${OPERATORS}/${NAME}.csr"
chmod 600 "$KEY" "$CRT"

FINGERPRINT="$(bash "$FP_SCRIPT" "$CRT")"
EXPIRES="$(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)"

# nginx отдаёт клиентский отпечаток в SHA-1 ($ssl_client_fingerprint),
# поэтому для allowlist шлюза нужен именно он. SHA-256 выше — для человека
# и для сверки: его удобнее диктовать и сравнивать глазами.
FP_SHA1="$(openssl x509 -in "$CRT" -noout -fingerprint -sha1 \
  | sed 's/.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')"

# ── Реестр операторов ───────────────────────────────────────────────────────
# Один файл-источник правды: имя, оба отпечатка, срок.
# Из него генерируется конфиг allowlist для nginx.
REGISTRY="${DIR}/operators.tsv"
if [[ ! -f "$REGISTRY" ]]; then
  printf '# name\tsha1\tsha256\texpires\n' > "$REGISTRY"
fi
# Убираем прежнюю запись с тем же именем (перевыпуск)
grep -v -P "^${NAME}\t" "$REGISTRY" > "${REGISTRY}.tmp" 2>/dev/null \
  || grep -v "^${NAME}	" "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"
printf '%s\t%s\t%s\t%s\n' "$NAME" "$FP_SHA1" "$FINGERPRINT" "$EXPIRES" >> "$REGISTRY"

# ── Конфиг allowlist для nginx ──────────────────────────────────────────────
# Отзыв сертификата = удалить строку из operators.tsv, перегенерировать
# этот файл и выполнить `nginx -s reload`. Перевыпускать CA не нужно.
NGINX_ALLOWLIST="${ROOT}/config/nginx/operators-allowlist.conf"
{
  echo "# Автогенерация: scripts/generate-operator-cert.sh"
  echo "# Не редактируйте вручную — правьте ${REGISTRY##*/} и перезапустите скрипт."
  echo "#"
  echo "# Отзыв доступа: удалите строку оператора из operators.tsv,"
  echo "# выполните любой выпуск заново (или regenerate-allowlist), затем nginx -s reload."
  echo ""
  echo "map \$ssl_client_fingerprint \$operator_allowed {"
  echo "    default 0;"
  while IFS=$'\t' read -r n s1 s256 exp; do
    [[ "$n" == \#* || -z "$n" ]] && continue
    printf '    %s 1;  # %s (до %s)\n' "$s1" "$n" "$exp"
  done < "$REGISTRY"
  echo "}"
} > "$NGINX_ALLOWLIST"

# Все SHA-256 отпечатки — для приложений, которые сверяют их сами
ALL_FPS="$(awk -F'\t' '!/^#/ && NF {print $3}' "$REGISTRY" | paste -sd, -)"
OPERATOR_COUNT="$(awk -F'\t' '!/^#/ && NF' "$REGISTRY" | wc -l | tr -d ' ')"

cat <<EOF

════════════════════════════════════════════════════════════════
  Сертификат оператора «${NAME}» выпущен
════════════════════════════════════════════════════════════════

  Сертификат:   ${CRT}
  Ключ:         ${KEY}
  SHA-256:      ${FINGERPRINT}
  Действует до: ${EXPIRES}

  Всего операторов в реестре: ${OPERATOR_COUNT}
  Реестр:   ${REGISTRY}
  Allowlist: config/nginx/operators-allowlist.conf  (обновлён)

────────────────────────────────────────────────────────────────
  Что дальше
────────────────────────────────────────────────────────────────

1. Разложите allowlist по нодам, которыми управляете,
   и перезагрузите их шлюзы:

     scp config/nginx/operators-allowlist.conf  node:/path/config/nginx/
     ssh node 'docker compose exec nginx-operator nginx -s reload'

2. Скопируйте на машину оператора — по защищённому каналу:

     ${CRT}
     ${KEY}
     ${DIR}/ca.crt

   в папку operator-console/certs/

3. Запустите пульт:

     cd operator-console && ./up.sh

────────────────────────────────────────────────────────────────
  Важно
────────────────────────────────────────────────────────────────

  • Приватный ключ (${NAME}.key) не должен покидать машину оператора.
    Не отправляйте его почтой и мессенджерами — только scp или
    физическим носителем.

  • Потеряли устройство? Отзовите доступ:
      1) удалите строку «${NAME}» из ${REGISTRY##*/}
      2) перевыпустите любой сертификат (allowlist обновится)
      3) nginx -s reload на каждой ноде
    Остальные сертификаты продолжат работать, CA перевыпускать не нужно.

  • Срок действия ${DAYS} дней. Перевыпуск:
      FORCE=1 bash scripts/generate-operator-cert.sh ${NAME}

EOF
