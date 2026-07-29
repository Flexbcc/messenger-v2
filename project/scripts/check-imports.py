#!/usr/bin/env python3
"""
Ищет NameError до запуска контейнеров.

ЗАЧЕМ
    Python не проверяет имена при компиляции. Забытый импорт вида
        from fastapi import APIRouter, Depends      # нет Header
        ...
        authorization: str = Header(...)
    проходит `py_compile` без единой жалобы, а падает при импорте модуля —
    то есть уже в контейнере, где это выглядит как «нода не стартует».

    Именно так три раза подряд ложились home-ноды: Header, Body,
    append_key_event. Секунда этой проверки экономит цикл пересборки.

ЗАПУСК
    python3 scripts/check-imports.py                 # все сервисы
    python3 scripts/check-imports.py services/home-node

Код возврата 1, если что-то найдено — годится для CI и pre-commit.
"""
from __future__ import annotations

import ast
import builtins
import sys
from pathlib import Path

# Имена, которые есть всегда, хотя в коде не объявлены
ALWAYS = set(dir(builtins)) | {
    "__file__", "__name__", "__doc__", "__package__", "__spec__",
    "__loader__", "__builtins__", "__debug__",
}


def collect_defined(tree: ast.AST) -> set[str]:
    """Всё, что модуль импортирует или определяет сам."""
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                names.add((alias.asname or alias.name).split(".")[0])
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            names.add(node.id)
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
        elif isinstance(node, ast.Global):
            names.update(node.names)
        elif isinstance(node, ast.Nonlocal):
            names.update(node.names)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            target = getattr(node, "target", None)
            if isinstance(target, ast.Name):
                names.add(target.id)
        elif isinstance(node, ast.withitem):
            v = node.optional_vars
            if isinstance(v, ast.Name):
                names.add(v.id)
    return names


def check_file(path: Path) -> list[str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"))
    except SyntaxError as exc:
        return [f"строка {exc.lineno}: синтаксическая ошибка — {exc.msg}"]

    defined = collect_defined(tree)
    problems: dict[str, int] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            if node.id not in defined and node.id not in ALWAYS:
                problems.setdefault(node.id, node.lineno)

    return [f"строка {line}: '{name}' не импортировано и не определено"
            for name, line in sorted(problems.items(), key=lambda kv: kv[1])]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    targets = [Path(a) for a in sys.argv[1:]] or [root / "services", root / "shared"]

    files: list[Path] = []
    for t in targets:
        t = t if t.is_absolute() else root / t
        if t.is_file() and t.suffix == ".py":
            files.append(t)
        elif t.is_dir():
            files.extend(
                f for f in sorted(t.rglob("*.py"))
                if "__pycache__" not in f.parts
                and ".venv" not in f.parts
                and "tests" not in f.parts
            )

    total = 0
    for f in files:
        problems = check_file(f)
        if problems:
            total += len(problems)
            print(f"\n✗ {f.relative_to(root)}")
            for p in problems:
                print(f"    {p}")

    print()
    if total:
        print(f"Найдено проблем: {total} — эти модули упадут при импорте.")
        return 1

    print(f"✓ Проверено файлов: {len(files)}. Необъявленных имён нет.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
