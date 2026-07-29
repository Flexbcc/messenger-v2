# NEXT_TASK

_Обновлено: 2026-07-23_

## Завершено в этой сессии

- ✅ Фаза 2.1 — Подписанные User Records (Discovery Ed25519, verify на home-node)
- ✅ Фаза 2.2 — Multi-hop Relay (hop_count, MAX_HOPS=2, L2 hub escalation)
- ✅ Фаза 2.3 — Latency-aware routing (RTT в health.py, sort в federation.py)
- ✅ Фаза 2.4 — Backup routes + Home change notify (buffer fallback, outbox WS)
- ✅ Фаза 3.1 — Trust degradation (автопонижение L2→L1→L0 по офлайн-времени)
- ✅ Фаза 3.2 — Rate limiting (sliding window, 429, config через env)
- ✅ Фаза 3.3 — Mesh peer list в heartbeat (piggybacked peers, update_mesh_from_heartbeat_response)
- ✅ coturn + nginx-tls (docker-compose services, config/, scripts/enable-tls.sh)
- ✅ Task #37 — tests/test_federation_chain.py (22 теста, unit-уровень, без Docker)

## Следующие задачи (бэклог)

### Task #17 — Push-уведомления о входящем звонке в background (Flutter)
Приоритет: низкий (требует платформенной интеграции FCM/APNs).
Детали: home-node должен слать push при `call_offer` если WS клиента не активен.

### Task #38 — Запустить тесты в CI / добавить GitHub Actions workflow
Создать `.github/workflows/test.yml`:
- `pytest tests/` на Python 3.11
- `flutter test` на Flutter stable
- Запускать на push в main/dev

### Task #39 — Документация деплоя с TLS (обновить DEPLOY.md)
Описать шаги после `bash scripts/enable-tls.sh`:
- как обновить PUBLIC_URL в .env на https://
- как обновить mTLS при ротации сертификатов
- firewall ports для coturn (UDP 3478, 5349, 49152-65535)

### Task #40 — PostgreSQL миграция (discovery-node, home-node)
Заменить SQLite + get_conn() на asyncpg/psycopg2.
Нужен ADR, schema migration скрипты, docker-compose override.

## Как продолжить

Запустить тесты локально:
```bash
cd project
python -m pytest tests/test_federation_chain.py -v
```

Для CI: Task #38.
Для продакшн-готовности: Task #39 (TLS docs) + Task #40 (PostgreSQL).
