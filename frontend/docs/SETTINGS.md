# frontend — настройки пользовательского приложения (ПК/телефон)

> **Статус (legacy-first):** основной UX — знакомые экраны (Уведомления,
> Оформление, Private Mode, Данные и хранилище, Устройства). Они пишут в
> legacy-ключи (`notif_*`, `theme_mode`, `pm_*`, `dl_*`). `CatalogSync`
> зеркалит их в `catalog.<id>`. «Расширенные настройки» — полный каталог спеки
> (node, sync, backup…); правки там идут в legacy через `SettingsCatalogBridge`.
>
> **Покрытие каталога (184 настройки / 18 секций):**
>
> | Слой | Кол-во | Смысл |
> |------|-------:|-------|
> | Видны в каталоге | **184** | все секции спеки отображаются |
> | Редактируемы (bool/select/text/number) | **131** | значения сохраняются в `catalog.<id>` |
> | Placeholder (action/list/secret/read_only) | **53** | snackbar, disabled, «скрыто», статика |
> | Влияют на поведение приложения | **~40+** | bridge + legacy; остальное persist для будущего backend |
>
> ⚠️ **Оставшийся пробел:** profile/identity/privacy/calls/node/sync/storage —
> значения сохраняются, но часть ещё не читается runtime (нет backend sync).
> Старые экраны (`NotificationsScreen` и др.) dual-write частично (theme).
>
> ⚠️ Синхронизация `profile`-настроек между устройствами **не реализована**
> (`LocalSettingsStore` — только локально).

## Источник истины
Настройки клиента описаны в едином пакете
[`../../ouo-settings-web-spec`](../../ouo-settings-web-spec) (копия ассета —
`app/assets/settings/ouo-settings-spec.json`):
- `ouo-settings-spec.json` — каталог настроек (id, type, default, ui, scope, storage, visible_if);
- `settings-values.schema.json` — схема значений;
- `default-state.json` — состояние по умолчанию;
- `SETTINGS-SPEC.md` — модель настройки и правила реализации.

**Целевая модель:** Flutter-клиент, Web/PWA, админ-панель и серверная валидация
читают **этот же** JSON. Сейчас клиент использует JSON для **каталога UI**;
runtime-поведение пока частично на legacy-экранах. Всего 18 секций, 184 настройки.

## Scope: что где живёт
| scope | смысл | синхронизация |
|-------|-------|---------------|
| `profile` (156) | привязано к identity пользователя | **целевая** — между устройствами; сейчас только локально |
| `device` (28)   | локально для конкретного устройства | НЕ синхронизируется |

`device`-секции: `notifications`, `media`, `appearance`, `developer`.
`storage`-поля: `profile_settings` (обычные), `local_encrypted` (secret — PIN,
ключи, пароли; никогда не логируются и не уходят в аналитику), `none` (action).

## Секции настроек (все — в этом приложении)
Профиль: `profile`, `identity`, `privacy`, `security`, `hidden_chats`,
`contacts`, `messages`, `sync`, `devices`, `calls`, `data`.
Локальные (device): `notifications`, `media`, `appearance`, `developer`.
Кросс-проектные (см. ниже): `node`, `storage_ownership`, `backup`.

### Реализация по секциям (кратко)
| Секция | В каталоге | Поведение |
|--------|:----------:|-----------|
| profile | ✅ | display_name через API; остальное — только каталог |
| identity, messages, sync, calls | ✅ | только каталог |
| privacy, contacts | ✅ | lists — placeholder; trust/block — отдельные stores |
| security, hidden_chats | ✅ | PIN/fake PIN — `PinSecurity`; остальное — каталог |
| notifications, appearance, media | ✅ | параллельные экраны с legacy-ключами |
| devices, data, developer | ✅ | частично (DevicesScreen, clear cache, DebugLog) |
| node, storage_ownership, backup | ✅ | node: runtime + mesh; storage_ownership: profile_settings → Home → media-node (`HOME_NODE_URL`); backup — каталог |

## Кросс-проектные секции — граница ответственности
Эти секции живут в UI клиента, но управляют поведением **ноды/хранилища**:
- **`node`** (13) — как приложение выбирает ноду: `node.mode`, `node.custom_enabled`,
  `node.custom_address`, `node.certificate_fingerprint`, `node.allow_fallback`,
  `node.allow_relays`, `node.allow_service_nodes`, прокси, мобильная сеть/роуминг.
  → это клиентская сторона; операторские настройки самой ноды — в
  [`../../client-node/docs/SETTINGS.md`](../../client-node/docs/SETTINGS.md).
- **`storage_ownership`** (21) — где хранить сообщения/медиа: `storage.message_location`,
  `storage.message_nodes`, `storage.replication_factor`, `storage.media_location`,
  S3-параметры, TTL, ключи, доступ. → реализуется нодой и storage-app; клиент лишь
  задаёт политику. См. [`../../storage-app/docs/SETTINGS.md`](../../storage-app/docs/SETTINGS.md).
- **`backup`** (7) — расписание/состав/шифрование резервных копий.

## Зависимости и правила
- `visible_if` скрывает дочерние настройки; скрытое не удаляется автоматически
  (`reset_when_hidden` — только по явному правилу). См. SETTINGS-SPEC.md.
- `secret` — только через `local_encrypted`, OS-keystore.
- `action` / `list` в каталоге — placeholder (snackbar / disabled editor).

## Связь с симуляцией
Визуализатор/симуляция (`../../ouo-settings-web-spec/docs/live-simulation.md`)
прогоняет ровно эти настройки, показывая их эффект в сети. Клиент и симуляция
делят один `ouo-settings-spec.json` — расхождений в **описании** быть не должно;
расхождение с **runtime** клиента — см. таблицу покрытия выше.
