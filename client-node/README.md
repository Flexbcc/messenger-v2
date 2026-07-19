# client-node — клиентская нода (упрощённая)

Та же кодовая база, что и у ноды проекта, НО минимум сервисов и настроек.
Пользователь хостит её сам, чтобы участвовать в общей сети.

## Что делает
- Поднимает свою `home-node` (личные аккаунты/чаты/группы, E2EE, WS).
- `storage-node` — офлайн-буфер. `relay-node` — микрохаб (опционально).
- **Находит общую сеть** через внешний `DISCOVERY_NODE_URL`:
  саморегистрация + heartbeat (исходящие). Attestation (`build_hash`, signing key)
  уходит в discovery при регистрации.

## Чего нода НЕ делает (важно)
- **Не получает** настройки, версии или инструкции обновлений из ответов discovery —
  registration/heartbeat только **отправляют** данные. Обновления — внешними
  скриптами (`slim-update.sh`).
- Media-прокси в рантайме может указывать на несуществующий `localhost:8004`
  (media-node в slim не входит).

## Не входит (это на стороне сети проекта, см. `../backend`)
- discovery ROOT, gateway, turn, media, admin/operator панели.

## Запуск
    cp .env.example .env
    #  ОБЯЗАТЕЛЬНО: DISCOVERY_NODE_URL=<discovery общей сети>
    #              HOME_NODE_PUBLIC_URL, JWT_SECRET, CLUSTER_ID
    docker compose up --build

## Обновления / регистрация
- ✅ `scripts/slim-update.sh` — **основной** путь обновления slim-ноды
  (rebuild+health-check+авто-откат), без git/node.profile. См. docs/SETTINGS.md §5.
- ✅ `scripts/sign-node-release.py` — подпись релизов (внешний инструмент).
- ⚠️ `scripts/node-update.sh`, `update-node.sh` — в slim **не работают** (нужны
  `config/deploy/node.profile` + git). Используйте `slim-update.sh`.
- ⚠️ `scripts/setup-node.sh`, `install-node.sh` — **наследие полного `project/`**,
  для slim client-node не подходят (ожидают discovery/media/turn/admin и другие пути).
  Для slim достаточно `.env` + `docker compose up`.

## Спека
`spec/` — только релевантное клиентской ноде (home/relay/storage/discovery/network/devops).
Настройки: [`node-settings-spec.json`](node-settings-spec.json) (29 настроек / 6 секций).
