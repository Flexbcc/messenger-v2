// История изменений: что, когда, старое → новое значение.
// Секретные поля не сохраняют реальные значения (маскируются).

import { isSecretId } from "./secrets.js";

let seq = 0;

/**
 * Создаёт запись истории. Для секретов old/new заменяются на маску.
 */
export function makeHistoryEntry(id, oldValue, newValue) {
  seq += 1;
  const secret = isSecretId(id);
  return {
    seq,
    id,
    ts: Date.now(),
    secret,
    old: secret ? "«•••»" : oldValue,
    next: secret ? "«•••»" : newValue
  };
}

export function formatValue(v) {
  if (v === undefined) return "—";
  if (typeof v === "string") return v === "" ? '""' : v;
  return JSON.stringify(v);
}
