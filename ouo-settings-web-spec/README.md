# OUO Settings — документация и интерактивный прототип

## Содержимое

- `ouo-settings-spec.json` — расширенная спецификация 184 настроек;
- `settings-values.schema.json` — JSON Schema для валидации состояния;
- `default-state.json` — начальное состояние;
- `SETTINGS-SPEC.md` — архитектурная документация;
- `web/` — React/Vite-прототип.

## Передача Cursor / Claude Code

Передайте агенту всю папку и задачу:

> Используй `ouo-settings-spec.json` как единый источник истины. Не хардкодь список настроек. Построй UI динамически, реализуй `visible_if`, валидацию по `settings-values.schema.json`, локальное сохранение состояния и отдельные редакторы списков. Секретные поля не логировать и не включать в аналитику.

## Быстрый запуск

```bash
cd web
npm install
npm run dev
```
