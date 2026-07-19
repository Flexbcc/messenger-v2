// Описания полей элементов управляемых списков (list) по item_type.
// Схема settings-values.schema.json описывает элементы как generic object,
// поэтому конкретную форму элемента задаём здесь — по одному редактору на тип.
// Подписи двуязычные: { ru, en }.

const L = (ru, en) => ({ ru, en });

// field: { key, label:{ru,en}, type: text|select|time|multiselect|boolean, options?, required? }
export const ITEM_SCHEMAS = {
  user: {
    label: L("Пользователь", "User"),
    idPrefix: "usr",
    titleField: "display_name",
    subtitleField: "username",
    fields: [
      { key: "display_name", label: L("Имя", "Name"), type: "text", required: true },
      { key: "username", label: L("Username", "Username"), type: "text" },
      { key: "public_id", label: L("Публичный ID", "Public ID"), type: "text" }
    ]
  },
  chat: {
    label: L("Чат", "Chat"),
    idPrefix: "cht",
    titleField: "title",
    subtitleField: "kind",
    fields: [
      { key: "title", label: L("Название", "Title"), type: "text", required: true },
      { key: "kind", label: L("Тип", "Type"), type: "select", options: ["private", "group", "channel"] }
    ]
  },
  device: {
    label: L("Устройство", "Device"),
    idPrefix: "dev",
    titleField: "name",
    subtitleField: "platform",
    fields: [
      { key: "name", label: L("Название", "Name"), type: "text", required: true },
      { key: "platform", label: L("Платформа", "Platform"), type: "select", options: ["android", "ios", "web", "desktop", "linux"] },
      { key: "last_active", label: L("Последняя активность", "Last active"), type: "text" },
      { key: "has_keys", label: L("Хранит ключи", "Holds keys"), type: "boolean" }
    ]
  },
  node: {
    label: L("Нода", "Node"),
    idPrefix: "node",
    titleField: "address",
    subtitleField: "region",
    fields: [
      { key: "address", label: L("Адрес", "Address"), type: "text", required: true },
      { key: "region", label: L("Регион", "Region"), type: "text" },
      { key: "role", label: L("Роль", "Role"), type: "select", options: ["storage", "relay", "service"] },
      { key: "encrypted_only", label: L("Только зашифрованные копии", "Encrypted copies only"), type: "boolean" }
    ]
  },
  time_range: {
    label: L("Интервал", "Time range"),
    idPrefix: "tr",
    titleField: "from",
    subtitleField: "to",
    fields: [
      { key: "from", label: L("С", "From"), type: "time", required: true },
      { key: "to", label: L("До", "To"), type: "time", required: true },
      { key: "days", label: L("Дни", "Days"), type: "multiselect", options: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] }
    ]
  },
  user_or_chat: {
    label: L("Пользователь или чат", "User or chat"),
    idPrefix: "uoc",
    titleField: "name",
    subtitleField: "kind",
    fields: [
      { key: "name", label: L("Название", "Name"), type: "text", required: true },
      { key: "kind", label: L("Тип", "Type"), type: "select", options: ["user", "chat"], required: true }
    ]
  }
};

export function schemaForItemType(itemType) {
  return ITEM_SCHEMAS[itemType] || null;
}

let counter = 0;
export function newItem(itemType) {
  const s = schemaForItemType(itemType);
  const prefix = s?.idPrefix || "item";
  counter += 1;
  const item = { id: `${prefix}_${Date.now().toString(36)}_${counter}` };
  for (const f of s?.fields || []) {
    if (f.type === "boolean") item[f.key] = false;
    else if (f.type === "multiselect") item[f.key] = [];
    else item[f.key] = "";
  }
  return item;
}

export function itemTitle(itemType, item) {
  const s = schemaForItemType(itemType);
  if (!s) return item.id;
  return item[s.titleField] || item.id;
}

export function itemSubtitle(itemType, item) {
  const s = schemaForItemType(itemType);
  if (!s || !s.subtitleField) return "";
  const v = item[s.subtitleField];
  return Array.isArray(v) ? v.join(", ") : v || "";
}
