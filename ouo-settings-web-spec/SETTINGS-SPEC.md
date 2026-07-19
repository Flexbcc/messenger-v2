# OUO Messenger — спецификация настроек

## Назначение

Этот пакет является единым источником истины для:

- Flutter-клиента;
- Web/PWA-клиента;
- административного интерфейса;
- Figma-прототипа;
- серверной валидации;
- Cursor и Claude Code.

## Основная модель настройки

Каждая настройка содержит:

```json
{
  "id": "security.pin_enabled",
  "title": "Включить PIN",
  "description": "Переключатель локальной защиты клиента.",
  "type": "boolean",
  "default": false,
  "data": {
    "json_type": "boolean"
  },
  "ui": {
    "control": "switch",
    "danger": false,
    "requires_confirmation": false
  },
  "scope": "profile",
  "storage": "profile_settings",
  "visible_if": null
}
```

## Типы

| type | JSON | UI |
|---|---|---|
| boolean | boolean | switch |
| single_select | string/integer | select |
| multi_select | array | multi-select |
| text | string | input/textarea |
| number | integer | number input |
| secret | string | password/PIN input |
| read_only | any | info row |
| action | null | button |
| list | array<object> | list editor |

## Зависимости

Дочерняя настройка отображается только при выполнении `visible_if`.

```json
{
  "setting": "contacts.trusted_enabled",
  "equals": true
}
```

или:

```json
{
  "setting": "storage.message_location",
  "in": ["selected_node", "replicated_nodes"]
}
```

## Правила реализации

1. Скрытая настройка не удаляется автоматически из состояния.
2. При отключении родительской функции интерфейс скрывает дочерние поля.
3. Сброс дочерних значений выполняется только по явному правилу `reset_when_hidden`.
4. `secret` никогда не логируется и не возвращается в аналитике.
5. `action` не хранится в конфигурации.
6. `read_only` заполняется системой.
7. Сервер и клиент валидируют значения по `settings-values.schema.json`.
8. UI строится из `ouo-settings-spec.json`, а не из захардкоженного списка.

## Хранение и владение данными

Раздел должен показывать не только переключатели, но и фактическое состояние:

- где находятся сообщения;
- где находятся медиа;
- какие устройства имеют ключи;
- какие ноды хранят зашифрованные копии;
- последнюю синхронизацию;
- последнюю резервную копию;
- возможность проверить целостность;
- возможность запросить удаление копий.

Важно: нода может хранить зашифрованный объект, но это не означает доступ к содержимому. В UI следует разделять:

- физическое хранение;
- возможность расшифровки;
- право на удаление;
- срок хранения;
- количество копий.
