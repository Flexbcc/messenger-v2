# PWA — тестовый деплой

Клиент на Flutter Web собирается в **статические файлы** (`build/web/`). Это и есть PWA: `manifest.json`, service worker, «Добавить на экран».

Бэкенд (home / media / discovery / …) — **отдельно**, как в `DEPLOY.md`. Браузер на телефоне должен достучаться до тех URL, которые зашиты при сборке.

## Что нужно для телефона

| Требование | Зачем |
|------------|--------|
| PWA открывается по **сети** (не `localhost` с ПК) | Телефон не видит `localhost` вашего Mac |
| URL нод в сборке = **LAN IP или домен** | `--dart-define=HOME_NODE_URL=...` при `build-web-pwa.sh` |
| **HTTPS** для полноценной установки на iOS | Safari без HTTPS часто не даёт «На экран Домой» как app |
| Порты нод открыты в локалке | CORS на бэкенде уже `*` (MVP) |

WebSocket берётся из `HOME_NODE_URL` (`http` → `ws`, `https` → `wss`). Если PWA на HTTPS, а Home на `http://IP:8001` — браузер **заблокирует** WS (mixed content). Решения: nginx с HTTPS-прокси на ноды (см. `deploy/nginx-pwa.example.conf`) или тест только по HTTP в локалке.

## Вариант 1 — быстрый тест в Wi‑Fi (без сервера в интернете)

На машине, где крутится docker-compose с нодами:

```bash
cd project/client/messenger_app

# Узнайте LAN IP (например 192.168.1.10)
ipconfig getifaddr en0   # macOS Wi‑Fi

export HOME_NODE_URL=http://192.168.1.10:8001
export MEDIA_NODE_URL=http://192.168.1.10:8004
export DISCOVERY_NODE_URL=http://192.168.1.10:8003

./scripts/build-web-pwa.sh
./scripts/serve-web-pwa.sh   # слушает 0.0.0.0:7357
```

На телефоне в той же сети: `http://192.168.1.10:7357`

- Android: обычно работает, можно «Установить приложение».
- iOS: для иконки на домашнем экране лучше HTTPS (вариант 2).

## Вариант 2 — один VPS / домашний ПК с nginx + HTTPS

1. Поднять ноды (`./scripts/setup-node.sh` / docker-compose).
2. Настроить nginx: статика PWA + прокси `/home/`, `/media/`, `/discovery/` (пример: `client/messenger_app/deploy/nginx-pwa.example.conf`).
3. Собрать клиент с **теми же URL**, что видит браузер:

```bash
export HOME_NODE_URL=https://messenger.example.com/home
export MEDIA_NODE_URL=https://messenger.example.com/media
export DISCOVERY_NODE_URL=https://messenger.example.com/discovery
./scripts/build-web-pwa.sh
```

4. Скопировать `build/web/` на сервер: `/var/www/messenger-pwa/`.

Подходит для **тестовой** публичной ссылки. Не выставляйте admin/health наружу без auth (см. `DEPLOY.md`).

## Вариант 3 — статика в облаке, бэкенд дома

- PWA: **Cloudflare Pages**, Netlify, GitHub Pages (бесплатно).
- API: домашний ПК + **Cloudflare Tunnel** / Tailscale Funnel → даёт HTTPS URL на ноды.

Сборка с URL туннеля:

```bash
export HOME_NODE_URL=https://home-xxxx.trycloudflare.com
# …
./scripts/build-web-pwa.sh
```

Загрузить содержимое `build/web/` в хостинг статики. При смене URL туннеля — **пересобрать** PWA.

## Локальная разработка (без деплоя)

```bash
./scripts/run-web.sh   # Chrome, localhost:7357, hot reload
```

## Автодеплой (рекомендуется)

```bash
cd project/client/messenger_app
cp deploy/pwa.env.example deploy/pwa.env   # один раз
ssh root@194.67.92.147 'bash -s' < deploy/setup-pwa-host.sh   # один раз на main
./scripts/ship-pwa.sh   # каждый релиз: build + rsync + restart
```

## Ограничения веб-версии (честно)

| Функция | Статус |
|---------|--------|
| Чаты / E2EE | ✅ |
| Уведомления в фоне | ⚠️ Notification API — нужно разрешение в Настройки → Уведомления |
| Push с сервера | ❌ не подключён |
| Звонки | ⚠️ нужны **HTTPS** (web) + **coturn** на worker (`TURN_SERVER_HOST=161.104.18.45`, порт 3478) |
| Установка PWA iOS | ⚠️ только **HTTPS** + «Поделиться → На экран Домой» |
| Установка PWA Android | HTTP может работать; HTTPS надёжнее |

См. `deploy/nginx-messenger.conf`, `project/deploy/coturn/turnserver.conf.example`.

## Ограничения (старое)

- Нет биометрии / secure vault файла (см. `platform_capabilities.dart`).
- Push-уведомления в браузере не подключены.
- Крипто и протокол — те же, что в desktop; отдельного «облегчённого» бэкенда не нужно.

## Чеклист перед раздачей тестерам

- [ ] Ноды online (admin или `/health`).
- [ ] `build-web-pwa.sh` с URL, доступными **с телефона тестера**.
- [ ] Открывается регистрация / вход.
- [ ] WebSocket: «Состояние соединения» → online.
- [ ] Отправка сообщения между двумя аккаунтами.

## Скрипты

| Скрипт | Назначение |
|--------|------------|
| `scripts/run-web.sh` | dev в Chrome |
| `scripts/build-web-pwa.sh` | release PWA → `build/web/` |
| `scripts/serve-web-pwa.sh` | раздача собранного билда по HTTP |
