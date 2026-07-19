// Логгер с обязательной редакцией секретов (требование 8).
// НИКОГДА не выводит значения secret-полей в консоль/лог.

import { isSecretId, redactSecrets } from "./secrets.js";

function scrub(arg) {
  if (arg && typeof arg === "object" && !Array.isArray(arg)) {
    // Похоже на объект значений настроек — маскируем секреты.
    return redactSecrets(arg);
  }
  return arg;
}

export const logger = {
  /**
   * Логирование изменения настройки. Для секретов значение не выводится.
   */
  change(id, value) {
    if (isSecretId(id)) {
      console.info(`[settings] изменено ${id} = «скрыто»`);
      return;
    }
    console.info(`[settings] изменено ${id} =`, value);
  },

  info(message, payload) {
    if (payload === undefined) console.info(`[settings] ${message}`);
    else console.info(`[settings] ${message}`, scrub(payload));
  },

  warn(message, payload) {
    if (payload === undefined) console.warn(`[settings] ${message}`);
    else console.warn(`[settings] ${message}`, scrub(payload));
  },

  error(message, payload) {
    if (payload === undefined) console.error(`[settings] ${message}`);
    else console.error(`[settings] ${message}`, scrub(payload));
  }
};
