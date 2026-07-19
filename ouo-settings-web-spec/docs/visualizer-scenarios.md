# Visualizer scenarios

Визуализатор — общая оболочка `web/` (React/Vite), режим **«Сеть OUO»** в верхней
панели. Внутри два раздела (категории): **«Сеть OUO»** и **«Безопасность OUO
Home»**. Обе категории используют один воспроизводимый event-sourcing движок
(`sim/engine.js` → `buildState(events, cursor)`); сцены описаны декларативно, UI
отделён от данных.

## Запуск

```bash
cd ouo-settings-web-spec/web
npm install
npm run dev
```

Затем: верхняя панель → «Сеть OUO» → категория «Безопасность OUO Home».
Управление: Play / Pause / Step / Prev / Reset, скорость x1–x10, View mode
(Просто / Технически / Угрозы / Ресурсы). Клик по событию перематывает состояние
сети; клик по объекту открывает карточку.

## Категория «Сеть OUO» (9 сценариев)

Базовые (раздел 19 исходного ТЗ) + после-MVP: две ноды на одной ноде; разные
публичные ноды; публичная ↔ NAT; две NAT через relay; локальная → внешний режим;
доставка медиа через S3 (два потока); ретрай; отказ relay → резервный маршрут;
офлайн-получатель.

## Категория «Безопасность OUO Home» (10 сценариев)

| # | Сценарий | Показывает |
|---|---|---|
| 1 | Нормальная работа | привязка телефона по QR, доверенный канал, файл в Secure Objects, capacity, состояние NORMAL |
| 2 | Домашний ПК выключен — fallback | Home offline → S3 / прямая доставка / локальная очередь |
| 3 | Рост личной нагрузки | вытеснение общественных задач, приоритет личного до 100% |
| 4 | Перегрузка: NORMAL → CRITICAL | admission controller: BUSY → OVERLOADED → CRITICAL и обратно |
| 5 | Сканирование сети | минимальный публичный интерфейс, запрос отклонён/rate-limited |
| 6 | Компрометация Relay | relay видит только метаданные; tamper/replay блокируются; смена маршрута |
| 7 | Взлом Home Node | диск украден (нет ключей) vs взломан процесс (изоляция, отзыв ключа, предупреждение устройств) |
| 8 | Уязвимость Relay → обновление | подписанный advisory → отключение relay → обновление → health check → восстановление |
| 9 | Устаревшая нода | личное работает, участие в сети ограничено, после обновления восстановлено |
| 10 | Sybil-атака | низкие лимиты, без критических ролей, контекстное доверие, маршруты из независимых источников |

## Цвета (не только цвет — есть иконки, подписи, легенда)

нормальная работа — зелёный; ограничение — жёлтый; перегрузка — оранжевый;
критическое — красный; зашифрованный поток — синий/фиолетовый; локальный
доверенный канал — бирюзовый; заблокированная атака — красный пунктир;
отключённая capability — серый.

## Модель данных (адаптирована под существующий движок)

Объекты несут `secState`, `capabilities[]`, `metrics{cpu,ram,disk,connections,
transfers,egress,personal,community}`, `security{version,supportState,
knownCriticalVulnerability}`, `storage{secureGb,libraryGb,freeGb}`. Рёбра —
`kind` из `EDGE_KIND` (`trusted`, `blocked`, `relay`, `media`, `delivered`, …).
Технические id, Node ID, типы событий и protocol-имена **не** переводятся;
остальной UI — RU/EN мгновенно.

## Файлы

```
web/src/sim/types.js                — модель (SEC_STATE, CAPABILITY, EDGE_KIND …)
web/src/sim/engine.js               — event-sourcing (не менялся)
web/src/sim/scenarios.js            — сценарии «Сеть OUO» (не менялись)
web/src/sim/securityScenarios.js    — сценарии «Безопасность OUO Home» (новое)
web/src/components/network/NetworkSim.jsx      — оболочка (категории, view mode)
web/src/components/network/NetworkCanvas.jsx   — SVG (новые типы, secState, метрики)
web/src/components/network/ResourcePanel.jsx   — ресурсы и состояние (новое)
web/src/components/network/InspectorPanel.jsx  — карточки (метрики/capabilities)
web/src/components/network/EventTimeline.jsx   — журнал событий
```

## Не реализовано (модель, не код)

Реальная криптография, WebRTC/NAT traversal, mTLS, сетевые сокеты, настоящее
S3/шифрование, реальный admission controller ОС. Всё симулируется; структура
данных и порядок событий приближены к будущей реальной архитектуре.
