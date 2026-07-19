// Единый источник знания о «секретных» настройках.
// Секрет = type === "secret" ИЛИ data.sensitive === true.
// Используется логгером и аналитикой, чтобы гарантированно не раскрывать значения.

import spec from "../settings-spec.json";

const SECRET_IDS = new Set();
for (const section of spec.sections) {
  for (const setting of section.settings) {
    if (setting.type === "secret" || setting.data?.sensitive === true) {
      SECRET_IDS.add(setting.id);
    }
  }
}

export function isSecretId(id) {
  return SECRET_IDS.has(id);
}

export function secretIds() {
  return Array.from(SECRET_IDS);
}

/**
 * Возвращает копию объекта значений с замаскированными секретами.
 * Секретные значения заменяются на "«скрыто»" (не логируем длину/содержимое).
 */
export function redactSecrets(values) {
  const out = {};
  for (const [id, value] of Object.entries(values || {})) {
    out[id] = isSecretId(id) ? "«скрыто»" : value;
  }
  return out;
}

/**
 * Возвращает копию значений БЕЗ секретных ключей (для аналитики).
 * Секреты не попадают в аналитику вообще — ни значение, ни маска.
 */
export function stripSecrets(values) {
  const out = {};
  for (const [id, value] of Object.entries(values || {})) {
    if (isSecretId(id)) continue;
    out[id] = value;
  }
  return out;
}
