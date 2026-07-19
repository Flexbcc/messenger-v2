# client-node — slim-нода пользователя

## Назначение

Минимальный стек для **самостоятельного хостинга**: своя Home Node + storage + relay. Подключается к **уже существующей** сети через `DISCOVERY_NODE_URL`.

## Папка в репозитории

`client-node/`

## Статус

**Активный.** Ядро работает; часть настроек из спеки — `planned`.

## Сервисы (`services/`)

| Сервис | Порт (default) | Роль |
|--------|----------------|------|
| `home-node` | 8001 (в compose) | Auth, чаты, WS, `/panel` владельца |
| `storage-node` | 8002 internal | Буфер |
| `relay-node` | 8005 internal | Микрохаб (опционально) |

**Нет:** discovery, gateway, turn, media, admin-server.

## UI

| URL | Роль |
|-----|------|
| `/panel` | Личная панель (wizard + обзор, обезличенная сеть) |
| `/ops` | — **не здесь** (только в main-node через прокси) |

## Запуск

```bash
cd client-node
cp .env.example .env
# DISCOVERY_NODE_URL, HOME_NODE_PUBLIC_URL, JWT_SECRET, CLUSTER_ID
docker compose up -d --build
```

Тестовый стек у нас: `HOME_PORT=18011`, `CLUSTER_ID=client-test`.

## Ключевые env

| Переменная | Назначение |
|------------|------------|
| `DISCOVERY_NODE_URL` | Адрес discovery **чужой** сети (обязательно) |
| `CLUSTER_ID` | Метка площадки (напр. `client-test`) |
| `HOME_NODE_PUBLIC_URL` | Как ноду видят снаружи |
| `ENROLLMENT_MODE` | Режим на стороне ноды (доверие решает discovery) |

## Обновления

- ✅ `scripts/slim-update.sh` — основной путь
- ⚠️ `setup-node.sh`, `install-node.sh` — **не для slim** (для полного project/)

## Спека настроек

`node-settings-spec.json` — 29 настроек / 6 секций; `docs/SETTINGS.md`.

## Зависимости

- **backend** или **project** — работающий `discovery-node`
- Сеть Docker `project_default` — для `discovery-node:8003` из контейнера

## Сборка используется в

- **main-node/** — `build.context: ../client-node`

## Версии

[CHANGELOG.md](CHANGELOG.md)
