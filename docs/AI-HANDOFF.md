# AI Handoff: что реально используется

Документ для другого агента. **Читай только то, что помечено LIVE.**  
Карта файлов и настроек: [`STRUCTURE.md`](STRUCTURE.md).  
Серверный протокол (цель + gap): [`SERVER-PROTOCOL-GUIDELINE-v0.3.md`](SERVER-PROTOCOL-GUIDELINE-v0.3.md).  
План развития (два трека): [`DEVELOPMENT-ROADMAP.md`](DEVELOPMENT-ROADMAP.md) · reality: [`reality/`](reality/).  
Всё остальное в workspace — зеркала, черновики, эксперименты: **не трогать**, пока явно не попросили.

_Обновлено: 2026-07-22_

---

## 1. Одна фраза о системе

**Децентрализованный мессенджер:** клиенты (Flutter) ↔ Gateway/Discovery (MAIN) ↔ Home/Media/Relay/Turn/Storage (WORKER).  
Прод-код и деплой живут в **`/Users/apple/messenger/project`** (git → Gitea).  
Активная разработка Flutter UI — в **`/Users/apple/messenger/frontend/app`** (часто впереди `project/client/…`; перед деплоем синхронизировать).

---

## 2. Топология (LIVE)

| Роль | IP | Что крутится |
|------|-----|----------------|
| **MAIN** | `194.67.92.147` | Gitea, discovery `:8003`, gateway `:8007`, admin `:9201` (только localhost), сайт/PWA (nginx HTTPS `:443`, legacy `:7357`) |
| **WORKER** | `161.104.18.45` | home `:8001`, media `:8004`, storage, relay, turn `:8006` |

На серверах путь: **`/opt/messenger/project`**.  
SSH с Mac: ключ **`~/.ssh/messenger_ops`**, user `root`.

| Сервис | URL |
|--------|-----|
| Home | `http://161.104.18.45:8001` |
| Media | `http://161.104.18.45:8004` |
| Discovery | `http://194.67.92.147:8003` |
| Gateway | `http://194.67.92.147:8007` |
| Gitea | `http://194.67.92.147:3000` · git `ssh://git@194.67.92.147:2222/flex/messenger.git` (user **flex**) |
| Сайт / PWA | `https://194.67.92.147/` · `https://194.67.92.147/app/` (**нужен доверенный cert/домен** для SW; самоподписанный ломает Service Worker) |

**Клиенты без домена:** macOS `.app` / будущий Android — работают по HTTP к worker.  
**Web/PWA в браузере:** без домена + Let's Encrypt (или Cloudflare Tunnel) — **не продукт**.

---

## 3. Карта папок: LIVE vs IGNORE

Корень workspace: `/Users/apple/messenger` — **не git-репозиторий**.

### LIVE — сюда смотреть

| Путь | Зачем |
|------|--------|
| **`project/`** | **Единственный деплой-репозиторий.** Docker Compose, сервисы, admin, scripts, deploy. Git remote = Gitea `flex/messenger`. |
| **`project/services/`** | Backend-ноды: `home-node`, `gateway-node`, `discovery-node`, `media-node`, `relay-node`, `storage-node`, `turn-node`. |
| **`project/shared/`** | Общий Python-код для нод (mesh, security…). |
| **`project/docker-compose.yml`** | Оркестрация контейнеров. |
| **`project/config/deploy/`** | `node.profile`, `workers.list`, `cluster.env.example`, `laptop.env` (локально, не в git). |
| **`project/scripts/`** | Деплой, enrollment, operator. Ключевые: `deploy.sh`, `node-update.sh`, `deploy-workers.sh`, `push-deploy.sh`, `enroll-worker.sh`, `deploy-https-site.sh`. |
| **`project/admin/` + `admin-server/`** | Operator Admin UI (порт 9201, только `127.0.0.1`). |
| **`project/docs/HANDOFF-AUTODEPLOY.md`** | Автодеплой, топология, troubleshooting. |
| **`frontend/app/`** | **Актуальный Flutter-клиент** (чаты, E2EE, settings, private mode, updates). Правки UI — здесь. |
| **`storage-app/app/`** | Desktop Storage App (личный blob-store, tray, Bonjour). |
| **`landing/`** | Статический лендинг (копируется на MAIN в `/var/www/messenger-site`). |
| **`releases/clients/manifest.json`** | Манифест версий клиентов (auto-update). Gateway отдаёт `GET /releases/clients/manifest.json`. |
| **`dist/clients/`** | Собранные артефакты (zip `.app`, web). Не исходники. |
| **`docs/BUILD_CLIENTS.md`** | Сборка клиентов / toolchain. |

Внутри `project/` также есть **`project/client/messenger_app/`** — копия Flutter для деплой-репо.  
**Правило:** правишь в `frontend/app` → перед релизом `rsync` в `project/client/messenger_app` (или наоборот синхронизируй явно). Не править только одну сторону и забывать вторую.

### IGNORE — не грузить в контекст

| Путь | Почему |
|------|--------|
| **`PRODUCT_BIBLE.md`, `design.md`, `screens.md`, `WORKSPACE.md`, `AUDIT.md`** | Черновики/устаревший split; не runtime. |
| **`/Users/apple/messenger-v2`** | Отдельный mirror (Gitea/GitHub). Не прод-pipeline. |
| **Flutter `build/`, Pods, `.dart_tool`, `data/`, `.env`** | Артефакты/секреты. |

Удалено из workspace (2026-07-22): `ouo/`, `ouo-settings-web-spec/`, `simulation/`, `backend/`, `client-node/`, `main-node/`, `messenger-sources-*.zip`.  
Каталог настроек клиента живёт в **`frontend/app/assets/settings/ouo-settings-spec.json`**.

---

## 4. Как устроено (runtime)

```
[Flutter macOS / Android / Web]
        │
        ├─ bootstrap / invite / release manifest ──► Gateway :8007 (MAIN)
        ├─ discovery catalog ──────────────────────► Discovery :8003 (MAIN)
        ├─ чаты, WS, settings ─────────────────────► Home :8001 (WORKER)
        ├─ медиа upload/download ──────────────────► Media :8004 (WORKER)
        └─ звонки (signaling + TURN) ──────────────► Home + Turn :8006 (WORKER)

[Storage App на ПК] ◄── PPC / Bonjour ──► клиент (опционально вместо S3)
```

- **E2EE** в клиенте (Signal Protocol, Dart). Ноды не читают plaintext сообщений.
- **Админка** — не публичный продукт; SSH-туннель на `9201`.
- **Автодеплой:** push в Gitea → webhook на MAIN → `deploy.sh` → workers.  
  На практике с Mac часто: **rsync + `docker compose build/up`** (если нет git-ключа для `git@`).

---

## 5. Где искать по задаче

| Задача | Куда идти |
|--------|-----------|
| API чатов / auth / WS | `project/services/home-node/app/` |
| Invite / routing / client manifest | `project/services/gateway-node/app/main.py` |
| Реестр нод / enrollment | `project/services/discovery-node/app/` |
| Медиа | `project/services/media-node/` |
| Compose / env | `project/docker-compose.yml`, `project/.env` (на сервере), `project/config/deploy/` |
| UI чатов / настройки / private mode | `frontend/app/lib/` |
| Конфиг URL нод в клиенте | `frontend/app/lib/config.dart` (`--dart-define=HOME_NODE_URL=…`) |
| Автообновление клиента | `frontend/app/lib/services/client_update_service.dart`, `releases/clients/manifest.json` |
| Лендинг | `landing/` |
| HTTPS / nginx сайт | `project/deploy/nginx-messenger-site.conf`, `project/scripts/deploy-https-site.sh` |
| Сборка клиентов | `scripts/build_clients.sh` (workspace), `frontend/app/scripts/build-*.sh` |
| Спеки / ADR (архитектура) | `project/spec/` — читать по необходимости, не «всё подряд» |

---

## 6. Операции (шпаргалка)

```bash
# SSH
ssh -i ~/.ssh/messenger_ops root@194.67.92.147
ssh -i ~/.ssh/messenger_ops root@161.104.18.45

# Health
curl -sf http://161.104.18.45:8001/health
curl -sf http://194.67.92.147:8003/health
curl -sf http://194.67.92.147:8007/health
curl -sk https://194.67.92.147/app/   # PWA (cert!)

# Деплой кода (часто так, без git push)
rsync -az --exclude=data --exclude=.env --exclude=.git \
  -e "ssh -i ~/.ssh/messenger_ops" \
  /Users/apple/messenger/project/ root@194.67.92.147:/opt/messenger/project/
# затем на сервере: docker compose build <svc> && docker compose up -d <svc>

# Flutter prod defines
HOME_NODE_URL=http://161.104.18.45:8001
MEDIA_NODE_URL=http://161.104.18.45:8004
DISCOVERY_NODE_URL=http://194.67.92.147:8003
GATEWAY_NODE_URL=http://194.67.92.147:8007
```

Версия клиентов: **`0.1.0+1` channel `beta`** (`pubspec.yaml` + manifest).

---

## 7. Известные ограничения (не чинить «случайно»)

1. **Web/PWA** требует **доверенный HTTPS (домен)**. Самоподписанный cert → SW fail.  
2. **Windows/Linux/iOS IPA** с Mac не собираются полноценно (нужен CI / другая ОС / Apple Dev).  
3. **Android** — toolchain + сеть к Maven; часто блокируется.  
4. **Не коммитить** `.env`, `laptop.env`, ключи.  
5. **Не трогать `simulation/`** без явной просьбы.  
6. Топ-level `/Users/apple/messenger` ≠ git; коммиты — в **`project/`**.

---

## 8. Порядок работы для агента

1. Уточнить: backend / Flutter / деплой / лендинг.  
2. Открыть **только LIVE-пути** из §3.  
3. Для прод-серверов сверять с `project/docs/HANDOFF-AUTODEPLOY.md`.  
4. UI-правки → `frontend/app`; перед выкладкой синк в `project/client/messenger_app` при необходимости.  
5. Не раздувать контекст `ouo-*`, `backend/`, `client-node/`, `simulation/`.

Если задача про «модульный monorepo» или симуляцию — сначала спросить пользователя: это **не** текущий прод-контур.
