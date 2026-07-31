# msng-test — тестовое окружение

Отдельный Docker Compose проект (project name: `msng`).
Не трогает основной `project/docker-compose.yml`.

## Топология

```
msng-discovery  :8103  — единый Discovery для всей федерации

msng-core-home  :8001  — главная нода (твоя)
msng-core-media :8004  — медиа-нода core
msng-core-turn  :8006  — TURN
msng-core-relay        — relay (internal)
msng-core-storage      — хранилище (internal)
msng-core-push         — push-proxy (internal)

msng-client-1-home  :8011  — клиентская нода 1
msng-client-1-media :8014
msng-client-2-home  :8022  — клиентская нода 2
msng-client-2-media :8024
msng-client-3-home  :8031  — клиентская нода 3
msng-client-3-media :8034

msng-storage-app :8042 — отдельное приложение хранилища

msng-web         :3000 — Flutter web (nginx)

msng-operator-gw :9443 — mTLS-шлюз: discovery admin API
                 :9444 — mTLS-шлюз: монитор home-ноды
```

## Управление: пульт вместо админки на сервере

Админки на сервере **нет**. Вместо неё — mTLS-шлюз, который отвечает
только тому, кто предъявил сертификат оператора.

Сам пульт живёт в `operator-console/` и запускается на машине оператора:

```
  твой ноутбук                        сервер
  ┌──────────────────┐                ┌─────────────────────┐
  │ operator-console │  ── mTLS ──▶   │ msng-operator-gw    │
  │ 127.0.0.1:9300   │   сертификат   │ :9443 :9444         │
  └──────────────────┘                │   │                 │
                                      │   ▼                 │
                                      │ discovery, home     │
                                      └─────────────────────┘
```

Кто стучится на 9443 без сертификата, получает обрыв на TLS-хендшейке —
до всякого HTTP. Для сканера порт выглядит мёртвым: ни баннера, ни версии,
ни формы для перебора паролей.

### Первый запуск

```bash
# 1. Выпустить сертификат оператора
cd ../project
bash scripts/generate-operator-cert.sh $(hostname -s)

# 2. Поднять шлюз
cd ../msng-test && ./up.sh gateway

# 3. Настроить и запустить пульт
cd ../operator-console
cp .env.example .env && nano .env
cp ../project/config/mtls/ca.crt certs/ca.crt
cp ../project/config/mtls/operators/$(hostname -s).crt certs/operator.crt
cp ../project/config/mtls/operators/$(hostname -s).key certs/operator.key
./up.sh

open http://127.0.0.1:9300
```

### Отзыв доступа

Потеряли устройство:

```bash
cd ../project
bash scripts/revoke-operator-cert.sh <имя>
docker compose -p msng exec msng-operator-gw nginx -s reload
```

Остальные сертификаты продолжат работать, CA перевыпускать не нужно.

## Сети

Стек разделён на две Docker-сети:

| Сеть | Кто внутри |
|------|-----------|
| `msng-net` | федерация: core, client-1/2/3, discovery, storage-app, web |
| `msng-admin-net` | шлюз оператора + core-сервисы + discovery |

Клиентские ноды в `msng-admin-net` **не входят** — они не видят шлюз
даже по DNS изнутри Docker.

## Что пульт может делать с чужими нодами

| Действие | Свои ноды | Чужие ноды |
|----------|-----------|------------|
| Телеметрия (CPU, RAM, сообщения, версия) | да | да, из heartbeat |
| Реестр федерации: approve, suspend, trust level | да | да |
| Журнал аудита | да | да |
| Конфигурация, перезапуск сервисов | да | **нет** |
| Доступ к переписке и ключам | нет | нет |

Чужой нодой управляет её владелец. Иначе обещание «твои данные на твоём
сервере» перестаёт быть правдой. Свои ноды перечисляются в
`OPERATOR_OWNED_NODES` в `.env` пульта.

## Быстрый старт

```bash
# 1. Поднять backend
./up.sh

# 2. Собрать web-клиент (нужен Flutter SDK)
./build-web.sh

# 3. Поднять web
docker compose -p msng up -d msng-web

# 4. Проверить что всё живо
./health.sh

# 5. Открыть
open http://localhost:3000
```

## macOS десктоп

```bash
# Сборка (нужен Xcode)
./build-macos.sh

# Или с конкретной нодой
HOME_NODE_URL=http://localhost:8011 ./build-macos.sh
```

## Управление

```bash
# Логи конкретной ноды
docker compose -p msng logs -f msng-core-home

# Перезапустить одну ноду
docker compose -p msng restart msng-client-1-home

# Остановить всё (данные сохраняются)
./down.sh

# Полный сброс (удалить все данные)
./down.sh --clean
```

## Клиенты по нодам

| Клиент  | Нода          | Home URL              |
|---------|---------------|-----------------------|
| Ты      | core          | http://localhost:8001 |
| Тест 1  | client-1      | http://localhost:8011 |
| Тест 2  | client-2      | http://localhost:8022 |
| Тест 3  | client-3      | http://localhost:8031 |
| Storage | storage-app   | http://localhost:8042 |
| Web     | любая нода    | http://localhost:3000 |
