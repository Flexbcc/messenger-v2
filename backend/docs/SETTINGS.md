# backend (админский) — настройки первичного обмена, поиска и статуса нод

Инфраструктурная/операторская сторона сети. Отвечает за bootstrap-обмен, поиск
нод, проверку доступности и статуса пользовательских нод, обновления и реакцию
на уязвимости. Машиночитаемый каталог —
[`../admin-settings-spec.json`](../admin-settings-spec.json) (6 секций / 21
настройка, формат `ouo-settings-spec.json`, привязка `env`). Модели поведения —
[`../../ouo-settings-web-spec/docs`](../../ouo-settings-web-spec/docs).

> ⚠️ `admin-settings-spec.json` — **документ-каталог**, не загружается admin UI.
> Реальность — `.env`, discovery admin API, hardcoded UI.

Формат спеки: `scope` = `network` (политика сети) / `admin` (панель) / `runtime`
(read_only); `storage` = `admin_env` / `admin_config` / `local_encrypted` /
`network_state` / `none`. Секции: `discovery`, `monitor`, `admission`,
`updates_publish`, `vulnerability`, `infra`. Ниже — пояснение к секциям.

## 1. Discovery / реестр нод (поиск и первичный обмен)
Сервис `services/discovery-node` (:8003) — ROOT на bootstrap-этапе.
- Регистрация ноды (id, публичный URL, версия, cluster, тип).
- **Heartbeat** и вычисление статуса: `online` / `offline` (протухший heartbeat).
  ✅ Порог настраивается: env **`DISCOVERY_OFFLINE_THRESHOLD_SECONDS`** (default
  120) в `discovery-node/app/config.py` (heartbeat нод = 60с).
- Резолв `UserID → HomeNode`. Список relay/storage/media/turn по типам.
- ✅ Relay fallback с **retry across relays** — `home-node/app/federation.py`
  (`_rank_reachable` / `_reachable_relays`).

## 2. Проверка доступности и статуса пользовательских нод
- **Node Monitor** (`admin/`, `admin-server/`, порт **9201** по умолчанию) —
  read-only таблица: статус, версия, последний heartbeat, тип, cluster.
  Опрашивает discovery; **browser-side ping** `/health` нод (5s refresh).
- ✅ **Активная health-проверка** (discovery loop): env
  `DISCOVERY_HEALTHCHECK_ENABLED` (+ interval/timeout) — `discovery-node/app/health.py`.
  Admin API: `POST /admin/monitor/health-check`.
- 🔶 Интервал опроса Node Monitor / набор колонок — **hardcoded** в UI
  (`monitor.poll_interval_s`, `monitor.visible_fields` = planned).

## 3. Enrollment / приём нод в сеть (admission)
- Режимы enrollment: **`legacy` / `strict` / `hybrid`** (`ENROLLMENT_MODE`).
  Одобрение новых нод: `scripts/approve-pending-nodes.sh`, `admin/enrollment.*`.
- **Fresh DB + strict:** пошаговый чеклист —
  [`../../docs/modules/backend/ENROLLMENT-STRICT.md`](../../docs/modules/backend/ENROLLMENT-STRICT.md)
  (`--list` / approve all / by `node_id`, `DISCOVERY_ADMIN_SECRET`, verify `node_token` claim).
- Политика допуска community-нагрузки на уровне сети — согласуется с
  `../../ouo-settings-web-spec/docs/capacity-and-admission-control.md`.

## 4. Обновления (издательская сторона)
Модель: `../../ouo-settings-web-spec/docs/update-security.md`.
- Подпись релизов: `scripts/sign-node-release.py` — env
  `RELEASE_SIGNING_SECRET` (HMAC) и `RELEASE_SIGNING_PUBLIC_KEYS` (Ed25519),
  проверка в `discovery-node/app/attestation.py`.
- 🔶 Каналы обновлений / защита от downgrade / мин. версия — **не реализованы**
  (`updates_publish.channels`, `downgrade_protection`, `min_supported_version`).

## 5. Реакция на уязвимости — 🔶 частично
Модель: `../../ouo-settings-web-spec/docs/vulnerability-response.md`.
- ✅ **Discovery admin API** (`/admin/vulnerability/*`): blocked versions CRUD,
  quarantine mode (`off`/`warn`/`isolate` — isolate исключает из публичного реестра),
  force_upgrade flag (хранится в БД).
- ❌ **Admin/operator UI** для vulnerability — нет (только API).
- ❌ **`force_upgrade` enforcement** — политика сохраняется, но не блокирует
  heartbeat/register.

## 6. Сервисы инфраструктуры и их параметры (`docker-compose.yml`)
| Сервис | Порт | Публикация |
|--------|-----:|------------|
| home-node | 8001 | host |
| storage-node | 8002 | internal only |
| discovery-node | 8003 | host |
| media-node | 8004 | host |
| relay-node | 8005 | internal only |
| turn-node | 8006 (+ coturn UDP 3478) | host (REST); relay — внешний coturn |
| gateway-node | 8007 / TLS 8447 | host |
| admin | 9201 (default) | localhost bind |

`INTERNAL_SECURITY_MODE` / `FEDERATION_ENVELOPE_MODE` — значение **`signed`**
(не `strict`) для строгого режима. Полный список env — `.env.example`.

## Границы
- Пользовательские настройки общения — клиент (`../../frontend/docs/SETTINGS.md`).
- Операторские настройки отдельной ноды — `../../client-node/docs/SETTINGS.md`.
- Хранилище — `../../storage-app/docs/SETTINGS.md`.
