# OUO Settings Sandbox

Интерактивная песочница настроек OUO Messenger. Не просто экран настроек, а
лаборатория: можно проверить каждую настройку, увидеть влияние одной на другую,
визуализировать внутреннюю работу мессенджера и протестировать UX до реализации
клиентов на Flutter и Web.

Интерфейс **полностью генерируется** из `ouo-settings-spec.json` (единый источник
истины). Список настроек нигде не захардкожен.

## Запуск

```bash
npm install
npm run dev
```

## Двуязычность (RU / EN)

- мгновенное переключение языка без reload/reinit — меняется только состояние;
- переводятся: разделы, названия, описания, значения (enum), кнопки, сообщения,
  ошибки, предупреждения, модальные окна, симуляторы, панели обучения;
- технические `id` и json-ключи (`security.pin_enabled`) **не** переводятся;
- источник истины (`ouo-settings-spec.json`) остаётся русским и не меняется;
  английский слой лежит отдельно в `src/i18n/spec.i18n.json` (генерируется
  скриптом; покрывает все 184 настройки, 18 разделов, 135 enum-токенов).

## Возможности

- все типы: boolean, single/multi-select, text, number, secret, read_only,
  action, list;
- `visible_if` (`equals` / `in`) с каскадом; скрытая настройка не удаляется;
- валидация по `settings-values.schema.json` с локализованной ошибкой у поля;
- локальное сохранение + импорт/экспорт JSON;
- секреты не логируются и не попадают ни в аналитику, ни в историю, ни в консоль
  (везде маскируются);
- модальные редакторы списков (user/chat/device/node/time_range/user_or_chat);
- confirm-диалоги для действий; опасные действия выделены в danger-зону;
- раздел «Хранение и владение данными»: физическое размещение, зашифрованные
  копии, устройства с ключами, ноды, TTL, реплики, синхронизация, бэкап;
- **панель «Как это работает?»**: что делает, какие компоненты затрагивает,
  риски/преимущества, зависимые настройки, схема и сценарии;
- **История изменений**: что, когда, старое → новое значение;
- **Режим разработчика**: вкладки JSON / State / Dependencies / Validation /
  Storage / Console (лог `SET id old → new`);
- **Симуляторы** (все 21 из ТЗ реализованы, реагируют на текущие настройки):
  Уведомления (preview / скрытый чат / DND), PIN и Fake PIN (попытки, таймер,
  блокировка, подставной профиль), Шифрование, Репликация, Маршрут и Доставка
  сообщений, Репликация медиа, Хранение файлов, QR (с TTL-таймером), Backup,
  Восстановление (пароль, шаги, контрольная сумма), Скрытые чаты (PIN / жест /
  секретная команда + флаги защиты), Trust Level (возможности по уровню),
  Device Pairing (методы подтверждения, sync истории), Node Switching /
  Network State (нода, прокси, relay, mobile/roaming), Синхронизация (сеть
  Wi-Fi/mobile, типы), TTL удаления, Auto Delete (возраст → хранится/удалено),
  Storage Usage (бары + лимит кэша).

## OUO Network Simulation Canvas

Второй режим приложения (переключатель «Настройки / Сеть OUO» в верхней панели) —
интерактивный симулятор децентрализованной сети OUO. Не статичная схема, а
воспроизводимая пошаговая модель на event-sourcing.

- **Canvas** (SVG): пользователи, устройства, личные / публичные / локальные ноды,
  ноды за NAT, relay, bootstrap, discovery; объекты перетаскиваются и кликаются.
- **Event timeline**: журнал событий (тип события + человекочитаемое описание).
  Клик по событию перематывает состояние сети на этот момент.
- **Пошаговое воспроизведение**: Play / Pause / Step / Prev / Reset, скорость
  x1–x10. Состояние строится фолдингом `events[0..cursor]` — детерминировано.
- **Inspector**: карточка выбранного объекта + панель «Почему это происходит?»
  для текущего события + легенда цветов связей.
- **9 сценариев**: базовые (раздел 19 ТЗ) — два пользователя на одной ноде; на
  разных публичных нодах; публичная ↔ NAT; две ноды за NAT через relay; локальная
  нода включает внешний режим. Плюс «после MVP»: доставка медиа через S3 (два
  потока — message path и media path, раздел 14); ретрай после сбоя доставки;
  отказ relay → резервный маршрут (reachableVia, раздел 10); офлайн-получатель с
  очередью на home-ноде.
- Полностью двуязычно; технические `id`, Node ID, типы событий не переводятся.
- Отправка текстового сообщения показана как процесс Identity → Home Node →
  Route Record → Route Selection → Delivery → ACK, а не «магическая линия».

Код: `src/sim/` (types, engine, scenarios — framework-agnostic движок и данные),
`src/components/network/` (NetworkSim, NetworkCanvas, EventTimeline,
InspectorPanel). Реальные крипто/WebRTC/сокеты не используются — всё
симулируется, но структура данных и последовательность событий соответствуют
будущей реальной архитектуре.

## Архитектура

| Модуль | Файл |
|---|---|
| `SettingsRenderer`   | `src/components/SettingsRenderer.jsx` |
| `SettingControl`     | `src/components/SettingControl.jsx` |
| `ListEditors`        | `src/components/ListEditors.jsx` |
| `DependencyResolver` | `src/services/DependencyResolver.js` |
| `ValidationService`  | `src/services/ValidationService.js` |
| `SettingsStorage`    | `src/services/SettingsStorage.js` |

Дополнительно: `i18n/` (движок локализации), `components/` (LearningPanel,
HistoryPanel, DevPanel, Simulators, Diagrams, Modal, StorageOwnershipPanel),
`services/` (secrets, logger, analytics, History, systemState, itemSchemas),
`content/learn.js` (база знаний для панели обучения).

## Данные

- `src/settings-spec.json` — копия `ouo-settings-spec.json` (источник истины);
- `src/settings-values.schema.json` — копия JSON Schema;
- `src/i18n/spec.i18n.json` — английский слой (title/description/enum);
- `src/default-state.json` — стартовое состояние.

> При изменении корневых `ouo-settings-spec.json` / `settings-values.schema.json`
> обновите копии в `src/` (Vite импортирует JSON из `src/`). Английский слой
> перегенерируется скриптом `gen_i18n.py`.
