# backend — полный бекенд сети проекта

Инфраструктурная («операторская») сторона: полный набор нод и панелей.
Это «нода проекта» — сложная, со всеми сервисами и мониторингом.

## Сервисы (`services/`)
| Сервис | Порт | Назначение |
|--------|-----:|------------|
| `home-node` | 8001 | auth, чаты/группы, сообщения, WS, федерация |
| `storage-node` | 8002 | буфер офлайн-сообщений (**internal only**) |
| `discovery-node` | 8003 | резолв UserID→HomeNode, реестр нод (ROOT) |
| `media-node` | 8004 | файлы (клиент шифрует до загрузки) |
| `relay-node` | 8005 | пересылка Packet (**internal only**) |
| `gateway-node` | 8007 / TLS 8447 | bootstrap routing, catalog, invite QR |
| `turn-node` | 8006 | REST credentials для звонков; UDP relay — coturn :3478 |

## Панели / прочее
- `admin/`, `admin-server/` — Node Monitor (:9201 по умолчанию).
- `operator/` — операторская консоль (:9300, localhost).
- `webview/` — просмотр спеки (markdown).
- `shared/` — общий код (security, prekeys).
- `config/`, `deploy/`, `scripts/`, `spec/`, `docs/` — конфиг, деплой, спека.

## Запуск
    cp .env.example .env   # заполнить секреты (ADMIN_PORT default в compose: 9201)
    docker compose up --build
    ./deploy.sh            # прод-деплой (см. DEPLOY через docs/)

## Отличие от client-node
`client-node/` — упрощённая пользовательская нода (home+storage+relay),
подключается к discovery ЭТОЙ сети. Здесь же — вся сеть целиком + discovery ROOT.

## Источник
Скопировано из `../project` (без `.venv/__pycache__/*.db`). Оригинал не трогается.
