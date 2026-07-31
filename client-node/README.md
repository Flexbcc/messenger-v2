# client-node

Полный стек нод мессенджера для самостоятельного хостинга.

Подключается к сети оператора через `DISCOVERY_NODE_URL` — discovery и admin/operator остаются у оператора.

## Состав

| Сервис | Порт | Роль |
|--------|------|------|
| home-node | 8001 | Auth, чаты, WebSocket, федерация, `/panel` |
| storage-node | internal | Буфер офлайн-сообщений |
| relay-node | internal | Пересылка пакетов |
| media-node | 8004 | Хранение зашифрованных файлов |
| turn-node | 8006 | Выдача TURN credentials для звонков |
| coturn | 3478/UDP | Ретрансляция медиапотока звонков (SRTP) |
| gateway-node | 8007 | Bootstrap, каталог нод, invite-ссылки |

## Требования

- VPS с публичным статическим IP
- Docker + Docker Compose v2
- Открытые порты в firewall:
  - TCP: `8001`, `8004`, `8006`, `8007`
  - UDP: `3478`, `49152–65535` (coturn)

> **Без публичного IP** звонки работают только внутри одной локальной сети.
> Это ограничение клиентской инфраструктуры — нода работает, но TURN недоступен извне.

## Быстрый старт

```bash
cd client-node

# Интерактивная настройка (рекомендуется для первого раза)
./scripts/setup.sh

# Или вручную:
cp .env.example .env
# Заполнить .env: DISCOVERY_NODE_URL, HOME_NODE_PUBLIC_URL, JWT_SECRET, TURN_SHARED_SECRET
# Заполнить config/coturn/turnserver.conf: external-ip, static-auth-secret

docker compose up -d --build
```

## Проверка

```bash
./scripts/health-check.sh
```

## Обновление

```bash
./scripts/update.sh
```

## Бэкап БД

```bash
./scripts/backup.sh

# Или через cron (ежедневно в 3:00):
# 0 3 * * * /path/to/client-node/scripts/backup.sh
```

## Конфигурация

Все параметры — в `.env`. Пример с комментариями: `.env.example`.

Ключевые переменные:

| Переменная | Обязательно | Описание |
|------------|:-----------:|----------|
| `DISCOVERY_NODE_URL` | ✅ | Адрес discovery оператора |
| `HOME_NODE_PUBLIC_URL` | ✅ | Публичный адрес вашей home-ноды |
| `JWT_SECRET` | ✅ | Секрет для токенов (мин. 32 символа) |
| `TURN_SHARED_SECRET` | ✅ | Общий секрет с coturn (мин. 32 символа) |
| `CLUSTER_ID` | ✅ | Уникальное имя вашей ноды |
| `ENROLLMENT_MODE` | — | `legacy`/`strict`/`hybrid` (уточнить у оператора) |

## Структура файлов

```
client-node/
├── docker-compose.yml       — конфигурация сервисов
├── .env.example             — шаблон конфигурации
├── .env                     — ваша конфигурация (не в git)
├── config/
│   ├── storage.json         — настройки хранилища media
│   └── coturn/
│       └── turnserver.conf  — конфиг coturn (заполнить external-ip)
├── data/                    — данные нод (не в git)
│   ├── home/
│   ├── storage/
│   ├── relay/
│   ├── media/
│   ├── media-meta/
│   ├── turn/
│   ├── gateway/
│   └── backups/
└── scripts/
    ├── setup.sh             — первоначальная настройка
    ├── update.sh            — обновление нод
    ├── health-check.sh      — проверка здоровья
    └── backup.sh            — бэкап SQLite
```

## Панель владельца

После запуска доступна по адресу: `http://<YOUR_VPS_IP>:8001/panel`

Показывает: статус нод, список пользователей, базовые настройки.
