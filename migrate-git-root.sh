#!/bin/bash
###############################################################################
# migrate-git-root.sh
#
# Переносит git-репозиторий из messenger/project/ в messenger/
# После этого под контролем версий окажется ВСЁ: project/, msng-test/,
# client-node/, storage-app/, landing/, frontend/, docs/, scripts/
#
# История коммитов сохраняется. Git сам определит переименования
# (services/... → project/services/...), поэтому `git log --follow` работает.
#
# Запуск:
#   cd ~/messenger
#   chmod +x migrate-git-root.sh
#   ./migrate-git-root.sh
###############################################################################
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "════════════════════════════════════════════════════════════"
echo "  Перенос git-репозитория: project/ → messenger/"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Корень: $ROOT"
echo ""

# ---------------------------------------------------------------- проверки
if [ ! -d "project/.git" ]; then
  echo "✗ project/.git не найден."
  if [ -d ".git" ]; then
    echo "  Похоже миграция уже выполнена — .git уже в корне."
  fi
  exit 1
fi

if [ -d ".git" ]; then
  echo "✗ В корне уже есть .git — миграция, похоже, уже сделана."
  exit 1
fi

if [ ! -f ".gitignore" ]; then
  echo "✗ Нет корневого .gitignore. Он нужен, иначе в репозиторий"
  echo "  попадут Pods (429 МБ) и собранные бинарники."
  exit 1
fi

# ------------------------------------------------- незакоммиченные изменения
cd project
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
cd "$ROOT"

echo "Незакоммиченных изменений в project/: $DIRTY"
echo ""

# ------------------------------------------------------------------ бэкап
BACKUP="$ROOT/../messenger-git-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
echo "→ Делаю бэкап .git ..."
tar -czf "$BACKUP" -C "$ROOT/project" .git
echo "  ✓ $BACKUP"
echo ""

# ------------------------------------------------------- шаг 1: перенос .git
echo "→ Переношу .git в корень ..."
mv project/.git .git
echo "  ✓ готово"
echo ""

# ------------------------------- шаг 2: убрать из индекса то, что теперь ignored
echo "→ Перечитываю .gitignore (убираю из индекса Pods, .db, build) ..."
git rm -r --cached . -q
git add -A
echo "  ✓ готово"
echo ""

# -------------------------------------------------------------- шаг 3: отчёт
echo "════════════════════════════════════════════════════════════"
echo "  Что попадёт в коммит"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Файлов в индексе: $(git ls-files | wc -l | tr -d ' ')"
echo ""
echo "По папкам верхнего уровня:"
git ls-files | awk -F/ '{print $1}' | sort | uniq -c | sort -rn
echo ""
echo "Размер того, что уйдёт в репозиторий:"
git ls-files -z | xargs -0 du -ch 2>/dev/null | tail -1
echo ""

# ------------------------------------------------- проверка на секреты
echo "→ Проверка: не попали ли секреты ..."
LEAKED=$(git ls-files | grep -E '(^|/)(\.env$|.*\.pem$|.*\.key$|node_signing_key|node_token|node_curve_key)' || true)
if [ -n "$LEAKED" ]; then
  echo "  ⚠️  ВНИМАНИЕ — в индексе есть похожее на секреты:"
  echo "$LEAKED" | sed 's/^/     /'
  echo ""
  echo "  Убрать:  git rm --cached <файл>"
else
  echo "  ✓ секретов не обнаружено"
fi
echo ""

LEAKED_DB=$(git ls-files | grep -E '\.db$' || true)
if [ -n "$LEAKED_DB" ]; then
  echo "  ⚠️  В индексе есть .db файлы:"
  echo "$LEAKED_DB" | sed 's/^/     /'
else
  echo "  ✓ .db файлов в индексе нет"
fi
echo ""

echo "════════════════════════════════════════════════════════════"
echo "  Дальше — вручную"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "1. Посмотреть что получилось:"
echo "     git status"
echo ""
echo "2. Закоммитить:"
echo "     git commit -m \"Restructure: move repo root to messenger/, add msng-test stack\""
echo ""
echo "3. Запушить:"
echo "     git push origin main"
echo ""
echo "Если что-то пошло не так — откат:"
echo "     rm -rf .git"
echo "     mkdir -p project && tar -xzf '$BACKUP' -C project"
echo ""
