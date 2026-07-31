# Changelog — client-node

## [Unreleased]

### Планируется
- 14 настроек из спеки (assistance, capacity, storage prefs)
- Полноценная auth на `/panel`

---

## [0.2.0] — 2026-07-15

### Добавлено
- `ops_proxy.py` — прокси `/ops` → internal admin (используется в main-node home).
- Панель: RAM/disk с процентами; ссылка на Operator Console.
- Подключение relay/storage к `project_default` для discovery.

### Изменено
- `DISCOVERY_NODE_URL` — через docker-сеть или host gateway к project discovery.
- `ENROLLMENT_MODE=strict` в .env примера.

---

## [0.1.0] — 2026-07-14

### Добавлено
- Выделение slim-стека из project.
- Owner panel `/panel` + wizard (`wizard.js`, setup API).
- Registration + heartbeat к discovery.
- `slim-update.sh`.

### Известные ограничения
- Media proxy указывает на localhost:8004 (media в slim нет).
- Discovery не отдаёт настройки ноде — только исходящая регистрация.
