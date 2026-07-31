# Структура проекта (LIVE)

Где что лежит после очистки workspace.  
Корень: **`/Users/apple/messenger`**.

Связанные доки: [`AI-HANDOFF.md`](AI-HANDOFF.md) · [`BUILD_CLIENTS.md`](BUILD_CLIENTS.md) · [`SERVER-PROTOCOL-GUIDELINE-v0.3.md`](SERVER-PROTOCOL-GUIDELINE-v0.3.md) · [`DEVELOPMENT-ROADMAP.md`](DEVELOPMENT-ROADMAP.md) · [`reality/`](reality/) · [`frontend/docs/SETTINGS.md`](../frontend/docs/SETTINGS.md)

_Обновлено: 2026-07-22_

---

## 1. Корень — что есть

```
messenger/
├── frontend/          ← Flutter-клиент (основная разработка UI)
├── project/           ← backend + docker + git деплоя (Gitea)
├── storage-app/       ← desktop-хранилище (PPC)
├── landing/           ← лендинг / скачивания
├── releases/          ← manifest версий клиентов
├── dist/              ← собранные zip/.app (артефакты)
├── scripts/           ← локальные скрипты (сборка, qa_bots)
└── docs/              ← эта документация
```

Ключевые файлы в `docs/`:

| Файл / каталог | Роль |
|----------------|------|
| `AI-HANDOFF.md` | LIVE vs IGNORE для агентов |
| `DEVELOPMENT-ROADMAP.md` | План R0–R5, два трека |
| `SERVER-PROTOCOL-GUIDELINE-v0.3.md` | ТЗ протокола + gap |
| `reality/` | As-is заметки (T2), шаблон `_TEMPLATE.md` |
| `BUILD_CLIENTS.md` | Сборка клиентов |

| Путь | Роль |
|------|------|
| `frontend/app/` | Код мессенджера (Dart/Flutter) |
| `project/` | Ноды, compose, admin, автодеплой |
| `project/client/messenger_app/` | Копия Flutter в деплой-репо (синхронизировать с `frontend/app`) |
| `storage-app/app/` | Storage App |
| `landing/` | Статика сайта |
| `releases/clients/manifest.json` | Версии / auto-update |
| `dist/clients/<дата>/` | Готовые билды |

---

## 2. Flutter-клиент — `frontend/app/`

```
frontend/app/
├── lib/
│   ├── main.dart              # вход
│   ├── config.dart            # URL нод (dart-define) + AppInfo version
│   ├── screens/               # экраны UI
│   ├── widgets/               # виджеты
│   ├── state/                 # Riverpod / контроллеры
│   ├── services/              # API, sync, lock, updates…
│   ├── models/                # модели (в т.ч. settings catalog)
│   ├── security/              # PIN, secure prefs, crypto helpers
│   ├── crypto/                # E2EE / Signal
│   ├── calls/                 # WebRTC
│   └── core/ theme/ utils/
├── assets/settings/           # ★ каталог настроек (JSON)
├── macos/ android/ ios/ web/ windows/ linux/
├── scripts/                   # build-web-pwa, ship-pwa…
├── pubspec.yaml               # версия 0.1.0+1, зависимости
└── test/
```

### Где настройки клиента

| Что | Где |
|-----|-----|
| **Спека каталога** (~184 ключа) | `assets/settings/ouo-settings-spec.json` |
| Seed для dev | `assets/settings/dev-catalog-seed.json` |
| Парсинг каталога | `lib/models/settings_catalog.dart` |
| UI каталога | `lib/screens/settings_catalog_*.dart` |
| Runtime values | `lib/state/settings_catalog_controller.dart` · `settings_runtime.dart` |
| Sync на Home Node | `lib/services/profile_settings_sync.dart` |
| Namespace prefs на аккаунт | `lib/services/account_settings_scope.dart` |
| Локальные prefs | SharedPreferences / `secure_prefs.dart` (по `storage` в спеке) |
| Описание покрытия | `frontend/docs/SETTINGS.md` |

Поле `storage` в спеке:
- `profile_settings` → сервер (Home), sync между устройствами  
- `local_encrypted` / device → только на устройстве  
- `none` → без persist  

### URL нод в клиенте

Задаются при сборке / run:

```
--dart-define=HOME_NODE_URL=...
--dart-define=MEDIA_NODE_URL=...
--dart-define=DISCOVERY_NODE_URL=...
--dart-define=GATEWAY_NODE_URL=...
```

Читаются в `lib/config.dart`. После invite могут переопределяться bootstrap’ом.

### Автообновление клиента

| Что | Где |
|-----|-----|
| Проверка версии | `lib/services/client_update_service.dart` |
| Баннер UI | `lib/widgets/client_update_banner.dart` |
| PWA reload | `lib/services/pwa_update_bridge*.dart` |
| Манифест на сервере | `releases/clients/manifest.json` → Gateway `GET /releases/clients/manifest.json` |

---

## 3. Backend / деплой — `project/`

```
project/                          ← git root → Gitea flex/messenger
├── docker-compose.yml
├── deploy.sh                     ← вход автодеплоя на MAIN
├── .env                          ← секреты на сервере (не в git)
├── services/
│   ├── home-node/                # чаты, auth, WS, profile settings
│   ├── gateway-node/             # invite, routing, client releases
│   ├── discovery-node/           # реестр нод
│   ├── media-node/               # медиа
│   ├── storage-node/
│   ├── relay-node/
│   └── turn-node/                # WebRTC TURN
├── shared/                       # общий Python (mesh, security)
├── admin/ + admin-server/        # Operator UI (:9201 localhost)
├── config/deploy/                # node.profile, workers, laptop.env*
├── scripts/                      # deploy, enroll, operator…
├── deploy/                       # nginx HTTPS site и т.п.
├── releases/clients/             # копия manifest в деплой-дереве
├── client/messenger_app/         # Flutter-копия для репо
├── docs/                         # HANDOFF-AUTODEPLOY.md и др.
└── spec/                         # ADR / API спеки
```

### Где настройки сервера / нод

| Что | Где |
|-----|-----|
| Env ноды | `project/.env` (на сервере `/opt/messenger/project/.env`) |
| Пример env | `project/.env.example` |
| Какие сервисы на машине | `config/deploy/node.profile` |
| Список workers | `config/deploy/workers.list` |
| Общие cluster secrets | `config/deploy/cluster.env` (+ example) |
| Ноутбук → SSH/Gitea | `config/deploy/laptop.env` (локально, не коммитить) |
| Compose ports/env | `docker-compose.yml` |

### Profile settings пользователя (на Home)

Хранятся на **home-node** (БД пользователя / profile), синк из клиента через `profile_settings_sync.dart`.  
Логика storage/ownership: `services/home-node/app/storage_policy.py`.

---

## 4. Storage App — `storage-app/`

```
storage-app/
├── app/                 # Flutter desktop
│   ├── lib/             # UI + headless server-ядро
│   ├── macos/ windows/ linux/
│   └── pubspec.yaml     # версия 0.1.0+1
└── docs/SETTINGS.md
```

Локальные настройки — SharedPreferences / secure storage внутри app (см. docs).

---

## 5. Лендинг и релизы

| Путь | Содержимое |
|------|------------|
| `landing/index.html` | Страница продукта / скачивания |
| `landing/style.css`, `app.js` | Стили, версия из manifest |
| `landing/downloads/` | zip клиентов |
| `landing/releases/clients/manifest.json` | копия для статики |
| `releases/clients/manifest.json` | канонический manifest |
| `dist/clients/<YYYYMMDD>/` | Messenger.app, StorageApp.app, web zip |
| На MAIN | `/var/www/messenger-site/` (nginx HTTPS) |

---

## 6. Скрипты

| Путь | Назначение |
|------|------------|
| `scripts/build_clients.sh` | Сборка клиентов → `dist/` |
| `scripts/generate-release-manifest.sh` | Обновить manifest из pubspec |
| `scripts/qa_bots/` | QA против live нод |
| `project/scripts/deploy.sh` | Автодеплой на сервере |
| `project/scripts/node-update.sh` | git pull + compose rebuild |
| `project/scripts/deploy-https-site.sh` | HTTPS лендинг + PWA |
| `frontend/app/scripts/build-web-pwa*.sh` | Сборка PWA |

---

## 7. Быстрый поиск «куда править»

| Хочу изменить… | Файл / папка |
|----------------|--------------|
| Экран чата / UI | `frontend/app/lib/screens/` |
| Список настроек (ключи) | `frontend/app/assets/settings/ouo-settings-spec.json` |
| Поведение настройки | `frontend/app/lib/services/settings_runtime.dart` (+ actions) |
| URL бэкенда в клиенте | `frontend/app/lib/config.dart` + dart-define при сборке |
| API сообщений | `project/services/home-node/` |
| Invite / join | `project/services/gateway-node/` |
| Реестр нод | `project/services/discovery-node/` |
| Версию приложения | `frontend/app/pubspec.yaml` → `generate-release-manifest.sh` |
| Текст лендинга | `landing/index.html` |
| Порты / сервисы docker | `project/docker-compose.yml` |

---

## 8. Чего здесь больше нет (не искать)

Удалено из workspace: `ouo/`, `ouo-settings-web-spec/`, `simulation/`, `backend/`, `client-node/`, `main-node/`.  
Не путать с **`assets/.../ouo-settings-spec.json`** — это живой каталог в клиенте.

---

## 9. Где живут данные после регистрации (в т.ч. 184 настройки)

### 9.1 Каталог ≠ уже сохранённые значения

| Слой | Что это | Где |
|------|---------|-----|
| **Спека** (имена, типы, default) | 184 определения | `frontend/app/assets/settings/ouo-settings-spec.json` |
| **Значения на устройстве** | что выбрал пользователь | SharedPreferences (web → localStorage) |
| **Значения на сервере** | sync профиля | Home Node: колонка `users.profile_settings` (JSON) |

При **первом** создании аккаунта почти все 184 ключа **ещё не записаны** — UI берёт `default` из спеки.  
Persist появляется после изменения настройки (или batch push).

### 9.2 Имена ключей

В спеке id вида:

```
profile.display_name
privacy.last_seen
notifications.enabled
storage_ownership.mode
…
```

Локально (после логина, userId = `abc123`):

```
app_settings_u_abc123_catalog.profile.display_name
app_settings_u_abc123_catalog.privacy.last_seen
…
```

Формула: `app_settings_u_<userId>_catalog.<setting_id>`  
(см. `LocalSettingsStore` + `SettingsCatalogBridge.catalogKey`).

### 9.3 Разбиение по `storage` в спеке (184)

| `storage` | Кол-во | Куда пишется |
|-----------|--------|--------------|
| `profile_settings` | **157** | локально + blob на Home `PUT /users/me/profile-settings` |
| `local_encrypted` | **7** | только устройство (секреты / PIN-related) |
| `none` | **20** | не persist (кнопки action, часть read_only) |

Часть полей профиля (`display_name`, `username`, `bio`, phone, email) ещё и в колонках пользователя + `PUT /users/me`.

### 9.4 Как выглядит blob на Home Node

API: `GET/PUT /users/me/profile-settings`

```json
{
  "values": {
    "profile.display_name": "Иван",
    "profile.language": "ru",
    "privacy.last_seen": "contacts",
    "notifications.enabled": true
  },
  "lists": {
    "storage.message_nodes": ["node-id-1"]
  }
}
```

В SQLite home-node: таблица `users`, колонка **`profile_settings`** (JSON).

### 9.5 Web: физически где на диске/в браузере

Flutter Web → `shared_preferences` → **localStorage** origin’а  
(например `https://194.67.92.147`).  
Ключи — те же `app_settings_u_…_catalog.…`.

На сервере (WORKER):  
`/opt/messenger/project/data/…` (sqlite home-node) — аккаунт + `profile_settings`.

### 9.6 Документация / скрины / старые сборки

| Что | Статус |
|-----|--------|
| `dist/`, `landing/downloads/` | Старые билды — артефакты, не «истина» |
| `PRODUCT_BIBLE.md`, `design.md`, `screens.md`, `docs/legacy/` | Могут быть **устаревшими** |
| `frontend/docs/SETTINGS.md` | Про покрытие каталога — сверять с кодом |
| UI screenshots (`docs/ui-screenshots/` если есть) | Каталог экранов, не runtime |
