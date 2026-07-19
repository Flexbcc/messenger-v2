// SettingsStorage
// Локальное сохранение состояния (localStorage) + импорт/экспорт JSON.
//
// Важно:
//  - секреты НЕ логируются (используется logger, который их маскирует);
//  - скрытые настройки НЕ удаляются из состояния при сохранении.

import { logger } from "./logger.js";

const STORAGE_KEY = "ouo.settings.state.v1";

export const SettingsStorage = {
  /**
   * Загружает состояние из localStorage. Возвращает объект значений либо null.
   */
  load() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      logger.info("состояние загружено из localStorage");
      return parsed;
    } catch (err) {
      logger.error("не удалось прочитать состояние", { message: String(err) });
      return null;
    }
  },

  /**
   * Сохраняет состояние целиком (включая скрытые настройки — их не удаляем).
   */
  save(values) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(values));
      logger.info("состояние сохранено");
      return true;
    } catch (err) {
      logger.error("не удалось сохранить состояние", { message: String(err) });
      return false;
    }
  },

  clear() {
    localStorage.removeItem(STORAGE_KEY);
    logger.info("сохранённое состояние очищено");
  },

  /**
   * Экспорт состояния в JSON-строку (для скачивания файлом).
   */
  export(values) {
    return JSON.stringify(values, null, 2);
  },

  /**
   * Инициирует скачивание файла с текущим состоянием.
   */
  downloadFile(values, filename = "ouo-settings.json") {
    const blob = new Blob([this.export(values)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    logger.info("состояние экспортировано в файл", { filename });
  },

  /**
   * Разбирает импортируемый JSON. Бросает понятную ошибку при некорректном вводе.
   */
  parseImport(text) {
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error("Файл не является корректным JSON.");
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("Ожидается JSON-объект вида { \"setting.id\": значение }.");
    }
    return parsed;
  }
};
