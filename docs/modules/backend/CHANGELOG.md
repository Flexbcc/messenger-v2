# Changelog — backend

## [Unreleased]

### Добавлено
- [ENROLLMENT-STRICT.md](ENROLLMENT-STRICT.md) — чеклист fresh DB + strict, approve UI/script, verify token.
- `approve-pending-nodes.sh`: `--list`, `--help`, таблица pending, понятные ошибки 401/503/curl.

### Планируется
- Слияние с `project/` в один канонический путь (TBD)
- UI для vulnerability policy

---

## [0.3.0] — 2026-07-15

### Добавлено
- `admin_audit_log` в discovery — история approve/suspend/compromise.
- `GET /admin/audit/history`, заголовок `X-Operator-Id`.
- Страница **Узлы** (`/nodes`) — метрики CPU/RAM по реестру.
- `GET /api/monitor/registry/metrics` в admin-server.
- Группировка площадок по `CLUSTER_ID` в мониторе (`clusters.js`).

### Изменено
- `ENROLLMENT_MODE=strict` — новые ноды в `pending` (без auto-trust в strict).
- Grandfather trusted только в `legacy` при init DB.

### Исправлено
- Compromise/revoke через enrollment proxy + operator id.
- Admin `HOME_NODE_URL` → `project-home-node-1` (DNS-конфликт с client-node).

---

## [0.2.0] — 2026-07-14

### Добавлено
- Выделение `backend/` из `project/`.
- Документация SETTINGS, admin-settings-spec.json.
- Health-check loop discovery, relay retry в federation.

---

## [0.1.0] — ранее

### Добавлено
- 7 сервисов, enrollment, Node Monitor, mesh notify.
