# Changelog — project (dev / legacy)

## [Unreleased]

### Планируется
- Депрекейт в пользу единого `backend/` как единственного compose (TBD)

---

## [0.3.0] — 2026-07-15

### Добавлено
- Компактный `/setup`, группировка площадок в мониторе.
- Страница `/nodes`, audit log, strict enrollment.
- `admin` static используется main-node через volume.

### Изменено
- `HOME_NODE_URL` admin → `project-home-node-1`.
- `ENROLLMENT_MODE=strict` в `.env`.

### Исправлено
- Двойной discovery на :8003 (host uvicorn vs docker) — документировано в main-node CHANGELOG.

---

## [0.2.0] — 2026-07-14

### Добавлено
- Разбиение репо: копии в backend, frontend, client-node (см. WORKSPACE.md).
- Owner panel в home-node, Operator Admin enrollment rewrite.

---

## [0.1.0] — ранее

### Добавлено
- Полный messenger stack, Flutter client, federation, enrollment ADR.
