#!/usr/bin/env bash
###############################################################################
# push-all.sh — сохранить всю работу в git и отправить на сервер
#
# Делает по порядку:
#   1. Переносит репозиторий в корень messenger/, если он ещё в project/
#   2. Показывает, что попадёт в коммит, и проверяет на секреты
#   3. Коммитит и пушит
#
# Останавливается на каждом шаге, требующем решения. Ничего не удаляет
# без спроса, перед переносом делает бэкап .git.
#
#   ./push-all.sh              — обычный запуск
#   ./push-all.sh --dry-run    — показать, но не коммитить
###############################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

hr() { printf '─%.0s' $(seq 70); echo; }
step() { echo; echo "▸ $1"; hr; }


##############################################################################
# 0. Залипший замок
#
# git создаёт .git/index.lock на время операции и снимает после. Если процесс
# оборвался, файл остаётся, и любая следующая команда падает с
# «Unable to create index.lock: File exists».
#
# Проверяем, есть ли живой git-процесс. Если нет — замок осиротевший,
# снимаем его сами.
##############################################################################
clear_stale_lock() {
  local gitdir="$1"
  local lock="$gitdir/index.lock"
  [ -f "$lock" ] || return 0

  if pgrep -f "git" >/dev/null 2>&1 && pgrep -f "$gitdir" >/dev/null 2>&1; then
    echo "  ✗ Похоже, git сейчас работает в этом репозитории."
    echo "    Закройте другие окна с git и повторите."
    exit 1
  fi

  echo "  ⚠ Найден осиротевший $lock — снимаю."
  rm -f "$lock"
}

echo "════════════════════════════════════════════════════════════════════"
echo "  Сохранение работы в git"
echo "════════════════════════════════════════════════════════════════════"

##############################################################################
# 1. Где сейчас репозиторий
##############################################################################
step "СОСТОЯНИЕ"

if [ -d .git ]; then
  echo "  Репозиторий в корне messenger/ — под контролем всё."
  clear_stale_lock ".git"
  MIGRATED=1
elif [ -d project/.git ]; then
  echo "  Репозиторий пока внутри project/."
  clear_stale_lock "project/.git"
  echo "  Значит msng-test, operator-console, docs и scripts в него не входят."
  MIGRATED=0
else
  echo "  ✗ Репозиторий не найден ни в корне, ни в project/."
  exit 1
fi

##############################################################################
# 2. Перенос, если нужен
##############################################################################
if [ "$MIGRATED" = "0" ]; then
  step "ПЕРЕНОС РЕПОЗИТОРИЯ В КОРЕНЬ"

  cat <<'EXPLAIN'
  Сейчас git видит только содержимое project/. Всё, что лежит рядом —
  msng-test/, operator-console/, docs/, scripts/ — для него не существует
  и нигде не сохраняется.

  Перенос делает корнем репозитория саму папку messenger/. История
  коммитов сохраняется: git распознаёт переименования, и `git log --follow`
  продолжит работать.

EXPLAIN

  if [ ! -f .gitignore ]; then
    echo "  ✗ Нет корневого .gitignore — без него в репозиторий уедут"
    echo "    Pods (429 МБ), сборки и базы. Прерываю."
    exit 1
  fi

  read -p "  Перенести? (y/N) " ans
  if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "  Отменено. Дальше идти нет смысла — прерываю."
    exit 0
  fi

  BACKUP="$ROOT/../messenger-git-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "  → бэкап .git → $BACKUP"
  tar -czf "$BACKUP" -C "$ROOT/project" .git

  echo "  → переношу .git в корень"
  mv project/.git .git

  echo "  → перечитываю индекс с новым .gitignore"
  clear_stale_lock ".git"
  git rm -r --cached . -q
  git add -A

  echo "  ✓ перенос выполнен"
else
  step "ПОДГОТОВКА"
  git add -A
  echo "  ✓ изменения добавлены в индекс"
fi

##############################################################################
# 3. Что уедет
##############################################################################
step "ЧТО ПОПАДЁТ В КОММИТ"

FILES=$(git ls-files | wc -l | tr -d ' ')
echo "  Файлов под контролем: $FILES"
echo ""
echo "  По папкам:"
git ls-files | awk -F/ '{print $1}' | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
echo ""
echo "  Размер:"
git ls-files -z | xargs -0 du -ch 2>/dev/null | tail -1 | sed 's/^/    /'

##############################################################################
# 4. Секреты
##############################################################################
step "ПРОВЕРКА НА СЕКРЕТЫ"

LEAK=0

check_leak() {
  local pattern="$1" desc="$2"
  local found
  found=$(git ls-files | grep -E "$pattern" || true)
  if [ -n "$found" ]; then
    echo "  ✗ $desc:"
    echo "$found" | sed 's/^/      /'
    LEAK=1
  fi
}

check_leak '(^|/)\.env$'                        "файлы .env"
check_leak '\.key$'                             "приватные ключи"
check_leak '\.pem$'                             "сертификаты с ключами"
check_leak '(^|/)(node_signing_key|node_token|node_curve_key)$' "ключи нод"
check_leak 'config/mtls/operators/'             "сертификаты операторов"
check_leak '\.db$'                              "базы данных"
check_leak 'laptop\.env|gitea\.env'             "локальные конфиги деплоя"

if [ "$LEAK" = "0" ]; then
  echo "  ✓ секретов в индексе нет"
else
  echo ""
  echo "  Убрать из индекса, не удаляя с диска:"
  echo "      git rm --cached <файл>"
  echo ""
  read -p "  Всё равно продолжить? (y/N) " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "  Прервано."; exit 1; }
fi

##############################################################################
# 5. Коммит
##############################################################################
step "КОММИТ"

if git diff --cached --quiet; then
  echo "  Нечего коммитить — всё уже сохранено."
else
  CHANGED=$(git diff --cached --numstat | wc -l | tr -d ' ')
  echo "  Изменено файлов: $CHANGED"

  if [ "$DRY" = "1" ]; then
    echo ""
    echo "  --dry-run: коммит не делаю."
    echo "  Посмотреть подробности:  git status"
    exit 0
  fi

  DEFAULT_MSG="Add msng-test stack, operator console, admin UI fixes"
  echo ""
  echo "  Сообщение коммита (Enter — взять по умолчанию):"
  echo "    «$DEFAULT_MSG»"
  read -p "  > " MSG
  MSG="${MSG:-$DEFAULT_MSG}"

  git commit -m "$MSG"
  echo "  ✓ закоммичено"
fi

##############################################################################
# 6. Отправка
##############################################################################
step "ОТПРАВКА"

# ── ВАЖНО про два адреса ────────────────────────────────────────────────────
#
# origin (Gitea)  — корень репозитория совпадает с тем, что здесь.
#                   Отправляем спокойно.
#
# github          — ДРУГАЯ структура. Там Flexbcc/messenger — зонтичный
#                   репозиторий, где наш код лежит в подпапке project/,
#                   а рядом backend/, main-node/, ouo/, simulation/.
#
#                   Прямой `git push github main` заменит там всё содержимое
#                   структурой этого репозитория — то есть снесёт остальные
#                   папки. Поэтому автоматически туда НЕ пушим.
# ────────────────────────────────────────────────────────────────────────────

BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "  Ветка: $BRANCH"
echo "  Адреса:"
git remote -v | grep '(push)' | sed 's/^/    /'
echo ""

read -p "  Отправить в Gitea (origin)? (y/N) " ans
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
  echo "  Не отправлено. Коммит сохранён локально."
  echo "  Отправить позже:  git push origin $BRANCH"
  exit 0
fi

GITEA_KEY="${MESSENGER_OPS_KEY:-$HOME/.ssh/id_ed25519}"
export GIT_SSH_COMMAND="ssh -i ${GITEA_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=20 -p 2222"

if git push origin "$BRANCH"; then
  echo "  ✓ Отправлено в Gitea"
else
  echo ""
  echo "  ✗ Не удалось."
  echo "    Проверить доступ:  ssh -T git@194.67.92.147 -p 2222 -i $GITEA_KEY"
  echo "    Если на сервере есть чужие коммиты:"
  echo "        git pull --rebase origin $BRANCH && git push origin $BRANCH"
  exit 1
fi

echo
hr
echo "  Gitea обновлён:  http://194.67.92.147:3000/flex/messenger"
hr
cat <<'GITHUB'

  ПРО GITHUB

  Туда автоматически не отправляем. На github.com/Flexbcc/messenger
  другая структура: наш код там лежит в подпапке project/, а рядом
  backend/, main-node/, ouo/, simulation/ — они в этом репозитории
  отсутствуют.

  Обычный push перезаписал бы их. Как правильно синхронизировать,
  зависит от того, чем делался коммит «Sync project/ from flex/messenger»
  — если это отдельный скрипт или GitHub Action, запускать надо его.

GITHUB
