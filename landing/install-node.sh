#!/usr/bin/env bash
# OUO node bootstrap. Downloads a versioned release, verifies SHA-256, then
# hands control to the release's interactive installer.
set -euo pipefail

BASE_URL="${OUO_DOWNLOAD_BASE:-https://www.ouoapp.ru/downloads}"
VERSION="${OUO_NODE_VERSION:-0.1.0-beta.1}"
ARCHIVE="ouo-node-${VERSION}.tar.gz"

case "$(uname -s)" in
  Linux)  default_dir="${HOME}/.ouo/project" ;;
  Darwin) default_dir="${HOME}/.ouo/project" ;;
  *) echo "OUO-нода пока поддерживает Linux и macOS." >&2; exit 2 ;;
esac

INSTALL_DIR="${OUO_INSTALL_DIR:-$default_dir}"
for command in curl tar python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Не найден $command. Установите его и повторите команду." >&2
    exit 2
  }
done
command -v docker >/dev/null 2>&1 || {
  echo "Сначала установите Docker Desktop (macOS) или Docker Engine (Linux)." >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  echo "Docker установлен, но не запущен." >&2
  exit 2
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ouo-install.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

echo "OUO: скачиваю ноду ${VERSION}…"
curl --proto '=https' --tlsv1.2 --fail --show-error --location \
  --output "$work_dir/$ARCHIVE" "$BASE_URL/$ARCHIVE"
curl --proto '=https' --tlsv1.2 --fail --show-error --location \
  --output "$work_dir/$ARCHIVE.sha256" "$BASE_URL/$ARCHIVE.sha256"

expected="$(awk 'NR==1 {print $1}' "$work_dir/$ARCHIVE.sha256")"
case "$expected" in
  ''|*[!0-9a-fA-F]*) echo "Некорректная контрольная сумма релиза." >&2; exit 3 ;;
esac
[[ ${#expected} -eq 64 ]] || { echo "Некорректная контрольная сумма релиза." >&2; exit 3; }
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$work_dir/$ARCHIVE" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$work_dir/$ARCHIVE" | awk '{print $1}')"
fi
[[ "$actual" == "$expected" ]] || {
  echo "Проверка пакета не прошла. Установка остановлена." >&2
  exit 3
}

mkdir -p "$INSTALL_DIR"
tar -xzf "$work_dir/$ARCHIVE" -C "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR/install" "$INSTALL_DIR/scripts/"*.sh
echo "OUO: пакет проверен и распакован в $INSTALL_DIR"
exec "$INSTALL_DIR/install" --network public "$@"
