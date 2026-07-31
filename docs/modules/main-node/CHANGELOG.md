# Changelog — main-node

## [Unreleased]

### Добавлено
- Ссылка на strict enrollment checklist: [../backend/ENROLLMENT-STRICT.md](../backend/ENROLLMENT-STRICT.md).

### Планируется
- media-node опционально в compose
- Единый `.env` wizard для первого запуска

---

## [0.2.0] — 2026-07-15

### Добавлено
- Operator Console на **http://127.0.0.1:9205/ops** (прокси home → admin).
- Сервис `admin` в compose (internal, без порта 9206 наружу).
- Документация «три площадки»: project / operator-main / client-test.

### Изменено
- Отказ от внешнего :9206 — единая точка :9205/ops.
- Подключение к `project_default` только relay/storage (+ admin), home без конфликта DNS.

### Исправлено
- Регистрация в том же discovery, что и Operator Admin project.

---

## [0.1.0] — 2026-07-15

### Добавлено
- Первый compose: home + storage + relay на :9205.
- `CLUSTER_ID=operator-main`.
