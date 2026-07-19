// Аналитика с исключением секретов (требование 9).
// Секретные поля НЕ включаются в события аналитики вообще.

import { isSecretId, stripSecrets } from "./secrets.js";

// В прототипе события просто складываются в память; в бою — отправка на сервер.
const buffer = [];

export const analytics = {
  /**
   * Событие изменения настройки. Секреты не трекаются вовсе.
   */
  settingChanged(id) {
    if (isSecretId(id)) return; // секрет не попадает в аналитику
    const event = { type: "setting_changed", id, ts: Date.now() };
    buffer.push(event);
    return event;
  },

  /**
   * Снимок состояния для аналитики — без секретных ключей.
   */
  snapshot(values) {
    const event = { type: "snapshot", values: stripSecrets(values), ts: Date.now() };
    buffer.push(event);
    return event;
  },

  action(actionId) {
    const event = { type: "action", id: actionId, ts: Date.now() };
    buffer.push(event);
    return event;
  },

  _buffer() {
    return buffer;
  }
};
