# Устаревшее и дубликаты

Что **не удалено**, но не считается «главным» местом для новой работы.

## `project/` — оригинальный dev-стек

| | |
|---|---|
| **Было** | Монолитный репозиторий: все сервисы + Flutter client + admin |
| **Сейчас** | Активный **dev-стек на машине разработчика** (`docker compose`, :8001, admin :9201) |
| **Куда смотреть** | Для новой документации и долгосрочно — `backend/` (копия бекенда). Для правок «как у нас в dev» — по-прежнему `project/` |
| **Документация** | [modules/project/README.md](../modules/project/README.md) |

## Дубликаты кода

| Путь A | Путь B | Примечание |
|--------|--------|------------|
| `backend/services/*` | `project/services/*` | Одинаковая роль; правки иногда нужно синхронизировать |
| `client-node/services/*` | `project/services/home-node` (частично) | client-node — slim; home-node panel/wizard копируется в project |
| `frontend/app/` | `project/client/messenger_app/` | frontend — выделенный клиент; project — оригинал |

## Скрипты «не для slim»

В `client-node/scripts/`:

- `setup-node.sh`, `install-node.sh` — рассчитаны на **полный** `project/`, для slim не использовать.
- Для client-node/main-node: `.env` + `docker compose` + `slim-update.sh`.

## Корневые файлы (история)

| Файл | Назначение |
|------|------------|
| `WORKSPACE.md` | Описание разбиения на папки (2026-07-14) |
| `AUDIT.md` | Аудит доки vs код |
| `PRODUCT_BIBLE.md` | Продуктовое видение |
| `design.md`, `screens.md` | Ранний дизайн |
| `messenger-sources-*.zip` | Архив исходников |

## `ouo/`, `ouo-settings-web-spec/`

Спека и прототип **каталога настроек** (184 настройки). Исполняется в основном во `frontend/`. Отдельные deployable-модули не являются.

## Что планируется убрать из «активного» (не сделано)

- Единый источник правды вместо `project/` + `backend/` (миграция TBD).
- Автосинхронизация копий client-node ↔ project home-node (TBD).
