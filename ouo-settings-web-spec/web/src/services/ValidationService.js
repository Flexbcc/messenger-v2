// ValidationService
// Валидация значений настроек по settings-values.schema.json.
// Реализует подмножество JSON Schema, которое реально используется в схеме:
//   type, enum, minLength, maxLength, pattern,
//   minimum, maximum, items(type/enum), uniqueItems, minItems, maxItems,
//   required, additionalProperties.
//
// Сообщения об ошибках — на русском, привязаны к конкретному полю (id настройки).

import schema from "../settings-values.schema.json";

function jsonTypeOf(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (Number.isInteger(value)) return "integer";
  if (typeof value === "number") return "number";
  return typeof value; // string | boolean | object
}

function typeMatches(expected, value) {
  const actual = jsonTypeOf(value);
  const list = Array.isArray(expected) ? expected : [expected];
  return list.some((t) => {
    if (t === "number") return actual === "number" || actual === "integer";
    if (t === "integer") return actual === "integer";
    return actual === t;
  });
}

function safeRegex(pattern) {
  try {
    return new RegExp(pattern);
  } catch {
    return null;
  }
}

// Fallback-переводчик (RU), если извне не передан t().
const RU = {
  "valid.type": "Ожидается тип",
  "valid.enum": "Допустимые значения:",
  "valid.minLen": "Минимальная длина:",
  "valid.maxLen": "Максимальная длина:",
  "valid.pattern": "Значение не соответствует формату.",
  "valid.min": "Минимум:",
  "valid.max": "Максимум:",
  "valid.minItems": "Минимум элементов:",
  "valid.maxItems": "Максимум элементов:",
  "valid.unique": "Элементы не должны повторяться.",
  "valid.required": "Обязательное поле.",
  "valid.unknown": "Неизвестная настройка (нет в схеме)."
};
const defaultT = (k) => RU[k] || k;

/**
 * Валидирует одно значение против под-схемы поля.
 * Возвращает строку с первой ошибкой либо null.
 * @param {function} [t] — переводчик UI-ключей (valid.*).
 */
export function validateField(fieldSchema, value, t = defaultT) {
  if (!fieldSchema) return null;

  // type
  if (fieldSchema.type && !typeMatches(fieldSchema.type, value)) {
    return `${t("valid.type")} ${[].concat(fieldSchema.type).join(" | ")}.`;
  }

  const kind = jsonTypeOf(value);

  // enum
  if (fieldSchema.enum && !fieldSchema.enum.includes(value)) {
    return `${t("valid.enum")} ${fieldSchema.enum.join(", ")}.`;
  }

  // string
  if (kind === "string") {
    if (fieldSchema.minLength != null && value.length < fieldSchema.minLength) {
      return `${t("valid.minLen")} ${fieldSchema.minLength}.`;
    }
    if (fieldSchema.maxLength != null && value.length > fieldSchema.maxLength) {
      return `${t("valid.maxLen")} ${fieldSchema.maxLength}.`;
    }
    if (fieldSchema.pattern) {
      const re = safeRegex(fieldSchema.pattern);
      if (re && !re.test(value)) return t("valid.pattern");
    }
  }

  // number / integer
  if (kind === "number" || kind === "integer") {
    if (fieldSchema.minimum != null && value < fieldSchema.minimum) {
      return `${t("valid.min")} ${fieldSchema.minimum}.`;
    }
    if (fieldSchema.maximum != null && value > fieldSchema.maximum) {
      return `${t("valid.max")} ${fieldSchema.maximum}.`;
    }
  }

  // array
  if (kind === "array") {
    if (fieldSchema.minItems != null && value.length < fieldSchema.minItems) {
      return `${t("valid.minItems")} ${fieldSchema.minItems}.`;
    }
    if (fieldSchema.maxItems != null && value.length > fieldSchema.maxItems) {
      return `${t("valid.maxItems")} ${fieldSchema.maxItems}.`;
    }
    if (fieldSchema.uniqueItems) {
      const seen = new Set(value.map((v) => JSON.stringify(v)));
      if (seen.size !== value.length) return t("valid.unique");
    }
    if (fieldSchema.items) {
      for (let i = 0; i < value.length; i += 1) {
        const itemErr = validateItem(fieldSchema.items, value[i]);
        if (itemErr) return `#${i + 1}: ${itemErr}`;
      }
    }
  }

  return null;
}

function validateItem(itemSchema, value) {
  if (itemSchema.type && !typeMatches(itemSchema.type, value)) {
    return `ожидается тип ${[].concat(itemSchema.type).join(" | ")}`;
  }
  if (itemSchema.enum && !itemSchema.enum.includes(value)) {
    return `допустимо ${itemSchema.enum.join(", ")}`;
  }
  return null;
}

/**
 * Валидирует всё состояние. Возвращает { [id]: "сообщение" } только для
 * полей с ошибками. Учитывает required и additionalProperties.
 *
 * @param {object} values      — редактируемое состояние
 * @param {object} [visibility]— карта видимости; скрытые поля не проверяются
 */
export function validateState(values, visibility, t = defaultT) {
  const errors = {};
  const props = schema.properties || {};

  // required
  for (const reqId of schema.required || []) {
    if (visibility && visibility[reqId] === false) continue;
    if (!(reqId in values) || values[reqId] === undefined) {
      errors[reqId] = t("valid.required");
    }
  }

  for (const [id, value] of Object.entries(values)) {
    // additionalProperties: false
    if (schema.additionalProperties === false && !(id in props)) {
      errors[id] = t("valid.unknown");
      continue;
    }
    // Скрытые поля не валидируем (но и не удаляем — см. DependencyResolver).
    if (visibility && visibility[id] === false) continue;

    const err = validateField(props[id], value, t);
    if (err) errors[id] = err;
  }

  return errors;
}

/**
 * Валидирует значение одного поля по его id.
 */
export function validateById(id, value) {
  const props = schema.properties || {};
  if (schema.additionalProperties === false && !(id in props)) {
    return "Неизвестная настройка (нет в схеме).";
  }
  return validateField(props[id], value);
}

export function getFieldSchema(id) {
  return (schema.properties || {})[id] || null;
}
