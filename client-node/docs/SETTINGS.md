# client-node — настройки ноды (что настраивается на ноде)

Операторские настройки самой ноды. Машиночитаемый каталог —
[`../node-settings-spec.json`](../node-settings-spec.json) (6 секций / 29 настроек,
тот же формат, что `ouo-settings-spec.json`; каждое поле с привязкой `env` к
`.env`/`docker-compose`). Модели поведения —
[`../../ouo-settings-web-spec/docs`](../../ouo-settings-web-spec/docs).
Клиентская нода — упрощённая: минимум обязательного, безопасные дефолты.

Формат спеки: `scope` = `node` (конфиг) / `runtime` (наблюдаемое, read_only);
`storage` = `node_env` / `node_config` / `local_encrypted` / `node_state` / `none`.
Секции: `network`, `assistance`, `capacity`, `storage`, `updates`, `enrollment`.
Ниже — текстовое пояснение к секциям.

## 1. Идентичность и подключение к сети (`.env`)
| Переменная | Смысл |
|------------|-------|
| `DISCOVERY_NODE_URL` | discovery общей сети — как нода находит сеть (обязательно) |
| `HOME_NODE_PUBLIC_URL` | как ноду видно снаружи |
| `HOME_NODE_ID` / `RELAY_NODE_ID` / `STORAGE_NODE_ID` | идентификаторы |
| `CLUSTER_ID` | кластер |
| `JWT_SECRET` | подпись клиентских сессий |
| `NODE_RESOURCE_POLICY` | политика выбора relay/storage (`local`/`cluster`/`federated`) |
Нода **отправляет** регистрацию и heartbeat в discovery (attestation: build_hash,
signing key). **Не парсит** ответы discovery на предмет настроек или обновлений —
это делается внешними скриптами (`slim-update.sh`). См.
[`../../backend/docs/SETTINGS.md`](../../backend/docs/SETTINGS.md) про то, как
админ-бэкенд проверяет доступность/статус.

## 2. Помощь сети (network assistance) — 🔶 заготовка
Модель: `../../ouo-settings-web-spec/docs/network-assistance.md`.
⚠️ В коде ноды НЕ реализовано (`assistance.*` = `status: planned`). Ниже — целевая модель.
По умолчанию — **Personal only** (нода работает только на себя, ничего скрытно).
Опционально включаемые роли:
- `Limited network assistance`, `Public relay`, `Temporary storage`,
  `Discovery helper`, `Witness`.
Настройки: вкл/выкл помощь, разрешённые функции, лимиты ресурсов (см. §3).

## 3. Capacity & admission control — 🔶 заготовка
Модель: `../../ouo-settings-web-spec/docs/capacity-and-admission-control.md`.
⚠️ В коде ноды НЕ реализовано (`capacity.*` = `status: planned`). Ниже — целевая модель.
Приоритет: **личная нагрузка всегда выше**, community — только свободные ресурсы,
вытесняема. Настраивается:
- максимум ресурсов под community (CPU/RAM/диск/полоса);
- порог вытеснения community при росте личной нагрузки;
- резерв (reserve).
Жёсткой доли «40/60» нет — гарантированный приоритет.

## 4. Хранилище на ноде
- Локальный буфер (`storage-node`) и медиа-бэкенд. Выбор бэкенда:
  `local` / `s3` / `personal_pc` (см. storage-app). 🔶 `storage.media_backend` и
  `storage.buffer_limit_gb` как настройки ноды пока не читаются (`status: planned`).
- ⚠️ `STORAGE_CONFIG` в slim-ноде **мёртв**: его единственный потребитель —
  media-node, который из client-node исключён. Актуально только в полном `backend`.
- ⚠️ media-node исключён: нода стартует (есть дефолты), но media-прокси в рантайме
  будет указывать на несуществующий `localhost:8004` — доставка медиа через прокси
  не работает. Для «ноды только для себя» это приемлемо.
- Профиль: `../../backend/config/storage.examples`. Политику задаёт клиент
  (секция `storage_ownership`), нода — исполняет.

## 5. Обновления
Модель: `../../ouo-settings-web-spec/docs/update-security.md`.
- 🔶 Канал/автообновление/проверка как **рантайм-настройки ноды** не реализованы
  (`updates.channel/auto_update/verify_signature` = `status: planned`).
- ✅ **`scripts/slim-update.sh`** — самодостаточное обновление slim-ноды без git и
  `node.profile`: снапшот образов → `build --pull` → `up -d` → health-check
  home-node → **авто-откат** на прежние образы при сбое. Опц. `RELEASE_ENV=./release.env`.
- ⚠️ `scripts/node-update.sh` и `update-node.sh` в slim **не работают** (требуют
  `config/deploy/node.profile` + git — наследие `project/`-workflow). Используйте
  `slim-update.sh`.
- ✅ `scripts/sign-node-release.py` — подпись релизов (внешний инструмент).
- ⚠️ `scripts/setup-node.sh` и `install-node.sh` — **не для slim client-node**
  (ожидают полный стек project/ с discovery/media/turn/admin). Для slim: `.env` +
  `docker compose up`.

## 6. Enrollment / безопасность
- `ENROLLMENT_MODE` — `legacy` / `strict` / `hybrid` (poll enrollment/status на discovery).
- `NODE_TOKEN_PATH`, `ENROLLMENT_SECRET_PATH`, `NODE_SIGNING_KEY_PATH`, `NODE_BUILD_HASH`.
- `INTERNAL_SECURITY_MODE`, `FEDERATION_ENVELOPE_MODE` — значение **`signed`** (не `strict`)
  включает строгую проверку; по умолчанию `legacy`. Не заданы в docker-compose slim.
- Федерация: `FEDERATION_*` (nonce/audit/envelope) — защита межнодового обмена.

## Что НЕ настраивается на ноде
Пользовательские настройки общения (профиль/приватность/уведомления и т.д.) —
это клиент, см. [`../../frontend/docs/SETTINGS.md`](../../frontend/docs/SETTINGS.md).
