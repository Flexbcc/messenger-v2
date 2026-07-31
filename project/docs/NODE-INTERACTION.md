# Как работают ноды, клиенты и хранение данных

Практическое руководство для оператора сети и разработчика. Дополняет `spec/0102_DATA_FLOW.md`, `spec/0203_ROUTING.md`, ADR-0006/0009.

---

## 1. Главная идея

**Пользователь не «выбирает ноду» при каждом сообщении.** У него есть:

| Сущность | Что это |
|----------|---------|
| **UserID** | Стабильный идентификатор (из криpto-identity) |
| **Home Node** | «Дом» аккаунта — регистрация, WebSocket, синхронизация |
| **Discovery** | Справочник: `user_id → home_node_url`, каталог нод |
| **Gateway** | Публичный вход: bootstrap, каталог, invite |

**Нода** — это сервер с одной или несколькими ролями (home, relay, storage, media, discovery, gateway).  
**Клиент** — телефон/браузер. Своей ноды у обычного пользователя **нет и не нужно**.

---

## 2. Клиент без своей ноды — куда он привязывается?

Он привязывается к **чужому Home Node**, которым управляет оператор:

| Тип Home | Кто оператор | Пример |
|----------|--------------|--------|
| **Публичный пул** | Вы / сообщество | `CLUSTER_ID=public`, открытая регистрация или invite |
| **Корпоративный** | IT компании | `CLUSTER_ID=corp-acme`, только сотрудники (QR-invite) |
| **Self-hosted** | Сам пользователь | Домашний сервер, один кластер |

### «Открытые» ноды для всех

Да, так задумано:

- Оператор поднимает Home + вспомогательные ноды с `CLUSTER_ID=default` (или `public`).
- В Discovery ноды помечаются `trust_status=trusted`.
- Клиент подключается через **Gateway bootstrap** или **одноразовый invite (QR)**.
- Регистрация создаёт аккаунт **на этом Home**; запись `user_id → home_url` попадает в Discovery.

Пользователь **не владеет** инфраструктурой, но **владеет** ключами E2EE на устройстве. Смена Home (миграция) — отдельная операция в будущем.

### Текущий MVP

- Бэкенд: федерация, `cluster_id`, `/gateway/routing`, **invite API** — реализованы.
- Клиент: bootstrap через invite или ввод ссылки; fallback — `HOME_NODE_URL` при сборке.

---

## 3. Корпоративный остров + внешний мир

Переменные на всех нодах кластера (см. `config/deploy/cluster.env.example`):

```env
CLUSTER_ID=corp-acme
NODE_RESOURCE_POLICY=cluster    # только свои relay/storage/media
# NODE_RESOURCE_POLICY=federated  # + доверенные внешние ноды
ENROLLMENT_MODE=hybrid          # новые ноды — pending до approve
```

| Policy | Поведение |
|--------|-----------|
| `cluster` | Relay/Storage/Media — только с тем же `CLUSTER_ID` (закрытый контур) |
| `federated` | Можно доставлять через **доверенные** внешние ноды (транзит) |
| `local` | Жёсткие URL в `.env`, без relay fallback |

**«VPN без VPN»** — это Relay: зашифрованный пакет идёт Home A → Relay → Home B. Relay видит только соседние хопы, не текст.

Внешние кластеры подключаются через **trust в Discovery** (оператор approve), не через открытый порт везде.

---

## 4. Доставка сообщения (два пользователя, разные ноды, оба в движении)

Геолокация **не участвует** в маршрутизации. Важен только `user_id → home_node_url` в Discovery.

```
Клиент А → Home A
              ├─ получатель локальный? → WebSocket
              ├─ офлайн? → Storage (буфер, TTL)
              └─ другой Home? → Discovery lookup
                    ├─ прямой POST /internal/deliver
                    └─ иначе Relay → Home B → WS / Storage
```

Телефон в поезде переподключается к **тому же Home URL** по интернету. Home не «едет» с пользователем.

---

## 5. Где хранятся сообщения (важно)

### Что видит сервер

| Место | Содержимое | Срок |
|-------|------------|------|
| **Home DB** (`home.db`) | Ciphertext сообщений, метаданные чатов | Пока оператор не чистит / не настроит retention |
| **Storage DB** | Буфер офлайн (ciphertext) | TTL (напр. 30 дней), потом удаление |
| **Media** | Зашифрованные файлы | По политике media-node + S3 |
| **Discovery** | Индекс пользователей, **не** переписка | Постоянно |

Сервер **никогда не видит plaintext** — только E2EE ciphertext (см. `spec/0300_CRYPTO.md`).

### Где «настоящая» копия переписки

1. **Устройство отправителя** — локальная SQLite (`MessageCacheStore`).
2. **Устройство получателя** — то же после доставки.
3. **Home** — ciphertext для доставки на другие устройства и федерации (как у Signal/WhatsApp server-side store, но без доступа к тексту).

Это **не** «всё только на телефонах»: Home хранит шифротекст для синхронизации и мульти-девайса. Оператор ноды **не может прочитать** чаты без ключей на устройствах.

### Свой бэкап на ноде (ваша идея)

Очень уместно для self-hosted / корпоративного Home:

| Что бэкапить | Зачем |
|--------------|-------|
| `data/home/home.db` | Восстановление аккаунтов, ciphertext, устройств |
| `data/media/` или S3 | Вложения |
| `data/discovery/` | Только если свой Discovery |

Плюсы:

- Срок хранения **вы решаете** (годы, не лимит облака мессенджера).
- Размер диска **под ваш контроль**.
- Бэкап шифруется на диске (LUKS + encrypted dump).

Минусы / оговорки:

- Бэкап ciphertext ≠ чтение без ключей устройств.
- Юридически вы храните метаданные (кто с кем, когда) — политика retention нужна.
- Для **полного** восстановления после потери всех телефонов нужна отдельная схема escrow ключей (не в MVP).

Рекомендация: cron + `sqlite3 .backup` + rsync media → cold storage; тест restore раз в месяц.

---

## 6. Подключение клиента: QR-invite (одноразовый)

Оператор кластера генерирует invite в Operator Console или API:

```
POST /gateway/invite/create
Header: X-Gateway-Invite-Secret: ...

→ { token, join_url, expires_at }
```

QR / ссылка: `https://gateway.example/join?t=<token>`

Клиент:

1. `GET /gateway/invite/redeem/<token>` — получает `home_url`, `discovery_url`, `cluster_id`, routing.
2. Сохраняет bootstrap локально.
3. Регистрируется на указанном Home.
4. Токен **сгорает** (single-use).

Секрет: `GATEWAY_INVITE_SECRET` в `.env` на gateway (тот же на всех нодах кластера с gateway).

---

## 7. Топология (текущий прод)

```
MAIN  — Gitea, Discovery, Gateway, PWA-сайт
WORKER — Home, Storage, Media, Relay, Turn
Mac   — Operator Console (управление, не data plane)
```

Main **обязателен** как публичный вход и git/autodeploy; Home может жить на worker или переехать — архитектура это допускает.

---

## 8. Чеклист оператора

- [ ] Один `CLUSTER_ID` на всех нодах острова
- [ ] `JWT_SECRET` одинаковый везде
- [ ] `ENROLLMENT_MODE=hybrid` или `strict` для контроля нод
- [ ] `GATEWAY_INVITE_SECRET` для QR onboarding
- [ ] `NODE_RESOURCE_POLICY` — `cluster` или `federated` по политике
- [ ] Бэкап `home.db` + media по cron
- [ ] Клиенты подключаются через invite или публичный gateway

---

## Связанные файлы

| Файл | Тема |
|------|------|
| `spec/0203_ROUTING.md` | Маршрутизация |
| `spec/0700_DATABASE.md` | Схемы БД по ролям |
| `docs/architecture-network.md` | Client vs service-to-service |
| `config/deploy/cluster.env.example` | Общие настройки кластера |
| `services/gateway-node/app/invites.py` | Invite tokens |
