# Как работать модуль за модулем

## Принцип

Один чат / одна задача = **один модуль**. В контекст агента или в голову — только:

- `docs/modules/<module>/README.md`
- `docs/modules/<module>/CHANGELOG.md`
- код в папке `<module>/` в корне репо

Не тащите `project/` целиком, если правите `client-node/`.

## Перед началом задачи

1. Уточните модуль (таблица в [README.md](README.md)).
2. Откройте `README.md` модуля — порты, env, границы «что не входит».
3. Пробегите последние 3–5 записей `CHANGELOG.md` — не повторять уже сделанное.

## После завершения задачи

В `CHANGELOG.md` модуля добавьте секцию:

```markdown
## [0.x.y] — YYYY-MM-DD

### Добавлено
- ...

### Изменено
- ...

### Исправлено
- ...
```

Версионирование (рекомендация):

- **PATCH** (0.1.x) — багфиксы, мелкий UI.
- **MINOR** (0.x.0) — новая фича в рамках модуля.
- **MAJOR** (x.0.0) — ломающие изменения API/compose/env.

Если затронуты два модуля (например discovery + admin UI) — запись в **оба** CHANGELOG.

## Зависимости между модулями

| Если меняете… | Проверьте также… |
|---------------|------------------|
| `discovery-node` (в backend/project) | `client-node`, `main-node`, admin enrollment |
| `client-node/services/home-node` | `main-node` (сборка из client-node), `project/` копия |
| `admin/` UI | `admin-server/`, прокси `/ops` в home-node |
| `frontend/` API URLs | порты в `backend` / нодах |

## Для AI / Cursor

В промпт достаточно:

```
Модуль: client-node
Доки: docs/modules/client-node/README.md, CHANGELOG.md
Задача: ...
Не трогать: backend, project, frontend
```
