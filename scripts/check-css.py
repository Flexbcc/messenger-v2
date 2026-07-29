#!/usr/bin/env python3
"""
Ищет классы, которые используются в разметке, но не описаны в CSS.

ЗАЧЕМ
    Именно из-за этого страницы админки выглядели по-разному: разметка на
    месте, а оформления нет — браузер рисует голый HTML. Заметить это
    глазами трудно: часть классов совпадает с общими, часть нет, и страница
    выглядит «наполовину сломанной».

    Классов набралось 63 — на nodes.html приходилось 24, поэтому она
    и открывалась чёрным текстом на белом.

ЗАПУСК
    python3 scripts/check-css.py

Код возврата 1, если что-то не описано — годится для CI.
"""
from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ADMIN = Path(__file__).resolve().parent.parent / "admin"

# Классы, которые ставит JS по условию, или служебные — не требуют стиля
IGNORE = {
    "active", "hidden", "show", "open", "collapsed",
    "html", "body",
}


def css_classes() -> set[str]:
    """Всё, что описано в таблицах стилей."""
    names: set[str] = set()
    for f in ADMIN.glob("*.css"):
        names.update(re.findall(r"\.([a-zA-Z][\w-]*)", f.read_text(encoding="utf-8")))
    # Плюс классы из <style> внутри самих страниц
    for f in ADMIN.glob("*.html"):
        for block in re.findall(r"<style>(.*?)</style>", f.read_text(encoding="utf-8"), re.S):
            names.update(re.findall(r"\.([a-zA-Z][\w-]*)", block))
    return names


def used_classes(path: Path) -> set[str]:
    """Классы из атрибутов class= — включая шаблонные строки JS."""
    src = path.read_text(encoding="utf-8")
    found: set[str] = set()

    # Обычные атрибуты
    for m in re.findall(r'class="([^"]*)"', src):
        for c in m.split():
            # Пропускаем подстановки вида ${...}
            if "${" in c or c.startswith(("'", '"', "?", "$", "}")):
                continue
            found.add(c)

    # Шаблонные строки: class="pill ${cond ? 'a' : 'b'}"
    for m in re.findall(r"class=[\"'`]([a-zA-Z][\w\s-]*)", src):
        found.update(m.split())

    # Обрывки динамических классов: JS собирает их как `role-${type}`,
    # и в исходнике остаётся голый префикс. Стиля они не требуют —
    # проверять надо конкретные варианты (role-home и подобные).
    def is_fragment(c: str) -> bool:
        return c.endswith("-") or not re.match(r"^[a-zA-Z][\w-]*$", c)

    return {c for c in found if c and c not in IGNORE and not is_fragment(c)}


def main() -> int:
    if not ADMIN.is_dir():
        print(f"✗ Не найдена папка админки: {ADMIN}", file=sys.stderr)
        return 1

    defined = css_classes()
    problems: dict[str, set[str]] = defaultdict(set)

    files = sorted(ADMIN.glob("*.html")) + sorted(ADMIN.glob("*.js"))
    for f in files:
        missing = {c for c in used_classes(f) if c not in defined}
        if missing:
            problems[f.name] = missing

    print(f"Проверено файлов: {len(files)}")
    print(f"Классов описано в CSS: {len(defined)}")
    print()

    if not problems:
        print("✓ Все используемые классы описаны в стилях.")
        return 0

    total = 0
    for name in sorted(problems):
        missing = sorted(problems[name])
        total += len(missing)
        print(f"✗ {name}  ({len(missing)})")
        for c in missing:
            print(f"      .{c}")
        print()

    print(f"Не описано классов: {total}")
    print()
    print("Эти элементы отрисуются без оформления — добавьте правила")
    print("в admin/style.css либо уберите класс из разметки.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
