# Федерация — как это устроено

_Обновлено: 2026-07-23_

## Зачем

Мессенджер работает в децентрализованной топологии: у каждого оператора своя **Home Node**, пользователи зарегистрированы на ней. Когда Алиса (home-A) пишет Бобу (home-B), сообщение нужно доставить через сеть нод. Федерация — это весь механизм этой доставки.

---

## Топология нод

```
Discovery Node  ←  регистрация, heartbeat, реестр
     │
     ├── Home Node A  (пользователи Алисы)
     ├── Home Node B  (пользователи Боба)
     ├── Relay Node   (L1 — промежуточная пересылка)
     ├── Hub Node     (L2 — высоконагруженный relay)
     └── Storage Node (буфер офлайн-сообщений)
```

---

## Уровни доверия (Trust Levels)

Каждая нода получает уровень доверия при регистрации и может быть повышена вручную через admin-панель.

| Уровень | Название | Что может |
|---------|----------|-----------|
| L0 | local | Только свои клиенты, никакого транзита |
| L1 | relay | Может пересылать чужие сообщения |
| L2 | hub | Приоритетный relay, выступает хабом |

**Пороги для повышения (вручную подтверждает оператор):**
- L0 → L1: 1000 сообщений + 3 дня аптайма + <5% ошибок
- L1 → L2: 5000 сообщений + 14 дней + <2% ошибок

История продвижений хранится в таблице `trust_level_history`.

---

## Метрики нод

Каждая нода отправляет в heartbeat реальные метрики хоста:

- CPU: load_1m, cores, % использования
- RAM: total/used/% 
- Диск: used/total/%
- Аптайм в секундах
- Активные WS-соединения
- Сообщений за 24ч / всего
- Процент ошибок
- Звонков за 24ч

Discovery хранит всё это и отдаёт в `/registry/nodes` — admin UI рисует бары нагрузки.

---

## Маршрутизация сообщений (Фаза 2)

### Цепочка доставки

При отправке сообщения от Home A к Home B пробуются три пути по очереди:

```
1. Прямая доставка:  Home A  →  Home B  /internal/deliver
                                ↓ упала
2. Relay (L1/L2):   Home A  →  Relay  /relay/forward
                               Relay  →  Home B  /internal/deliver
                                         ↓ упала
3. Hub эскалация:              Relay  →  Hub  /relay/forward  (hop_count=2)
                                         Hub  →  Home B
                                                  ↓ все упали
4. Backup buffer:   Home A буферизует в Storage Node + enqueue outbox
```

### Параметр hop_count

В каждом relay-пакете есть `hop_count`:
- `hop_count=1` — первый relay-хоп (Home → Relay)
- `hop_count=2` — второй хоп (Relay → Hub)
- `MAX_HOPS=2` — relay с hop≥2 не эскалирует дальше (защита от петель)

### Выбор relay по задержке (Фаза 2.3)

Discovery измеряет RTT при каждом health-check (`health.py → _ping`) и сохраняет в поле `latency_ms`. Home-node сортирует кандидатов по этому значению перед ping-гонкой — быстрый relay выигрывает детерминированно, а не случайно.

### Backup route (Фаза 2.4)

Если упали все три пути (direct + relay + hub):
1. Сообщение немедленно буферизуется в Storage Node для каждого получателя
2. Fanout возвращает успех отправителю (сообщение не потеряно)
3. Outbox ретраит доставку с backoff (2с → 1ч максимум, 20 попыток)
4. При ререзолве: если Discovery вернул новый home_node_url — WS `home_changed` пушится локальным контактам

---

## Подписанные User Records (Фаза 2.1)

Discovery подписывает каждую запись `user_id → home_node_url` своим Ed25519-ключом. Home-node проверяет подпись перед использованием.

**Канонический payload подписи:**
```
"{user_id}|{home_node_url}|{updated_at}"  (UTF-8, base64url)
```

**Логика проверки (fail-open):**
- Нет подписи → warning в лог + принять (совместимость со старым Discovery)
- Подпись есть, но неверная → error + отказ от записи
- Подпись верна → доверяем

**Публичный ключ Discovery** доступен через `GET /discovery-pubkey` — home-node может закэшировать и периодически обновлять.

**Файлы:**
- `services/discovery-node/app/record_signer.py` — подпись
- `shared/security/record_verifier.py` — проверка (используется любой нодой)
- `services/discovery-node/app/main.py` — эндпоинт `/discovery-pubkey`

---

## Ключевые файлы

| Файл | Назначение |
|------|-----------|
| `services/home-node/app/federation.py` | Вся логика доставки: direct/relay/hub/buffer |
| `services/home-node/app/outbox.py` | Durable retry с re-resolve + home_changed notify |
| `services/home-node/app/fanout.py` | Fan-out по участникам, WS push, home_changed |
| `services/relay-node/app/main.py` | Relay + hub эскалация, hop_count guard |
| `services/discovery-node/app/health.py` | Health-check + измерение latency_ms |
| `services/discovery-node/app/routers/registry.py` | Реестр нод, heartbeat, user records |
| `services/discovery-node/app/routers/admin_enrollment.py` | Промоция trust level, история |
| `services/discovery-node/app/record_signer.py` | Ed25519 подпись user records |
| `shared/security/record_verifier.py` | Проверка подписи (шарится между нодами) |
| `shared/security/payload_builder.py` | Сборка wire-пакетов (relay forward + hop_count) |

---

## Admin API (только через admin-server, не напрямую)

```
GET  /api/monitor/registry/nodes/all          — список всех нод с метриками
GET  /api/monitor/registry/promotion-candidates — кандидаты на повышение
POST /api/monitor/registry/nodes/{id}/promote — повысить trust level
POST /api/monitor/registry/nodes/{id}/demote  — понизить trust level
```

Прямой доступ к Discovery из браузера заблокирован — всё через proxy в admin-server (защита от CORS + скрытие Discovery URL от оператора).

---

## Известные ограничения

- TLS между нодами не настроен (MVP — только локалка)
- Автоматической деградации trust level нет (если нода умерла на 2 недели — L2 остаётся)
- Rate-limit транзитных сообщений не реализован
- Mesh-синхронизация реестра: ноды не обмениваются списками между собой (один Discovery — SPOF)
