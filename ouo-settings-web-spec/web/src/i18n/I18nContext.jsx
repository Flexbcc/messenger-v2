import React, { createContext, useCallback, useContext, useMemo, useState } from "react";
import spec from "../settings-spec.json";
import layer from "./spec.i18n.json";
import { UI, uiText } from "./ui.js";

// Индекс id -> setting из спеки (RU-строки живут в спеке).
const SETTING = {};
for (const section of spec.sections) {
  for (const s of section.settings) SETTING[s.id] = s;
}
const SECTION = {};
for (const section of spec.sections) SECTION[section.id] = section;

const I18nContext = createContext(null);

export const LANGS = [
  { code: "ru", label: "RU" },
  { code: "en", label: "EN" }
];

/**
 * Провайдер локализации. Переключение языка мгновенное — меняется только
 * состояние lang, без reload/reinit. Технические id/ключи не переводятся.
 */
export function I18nProvider({ children }) {
  const [lang, setLang] = useState(() => localStorage.getItem("ouo.lang") || "ru");

  const setLangPersist = useCallback((next) => {
    setLang(next);
    localStorage.setItem("ouo.lang", next);
  }, []);

  const api = useMemo(() => {
    // UI chrome
    const t = (key) => uiText(key, lang);

    // Заголовок настройки: EN из слоя, RU из спеки, иначе fallback.
    const tset = (id) => {
      const en = layer.settings[id]?.title?.en;
      const ru = SETTING[id]?.title;
      return lang === "en" ? en || ru || id : ru || en || id;
    };
    const tdesc = (id) => {
      const en = layer.settings[id]?.description?.en;
      const ru = SETTING[id]?.description;
      return lang === "en" ? en || ru || "" : ru || en || "";
    };
    // Заголовок раздела.
    const tsec = (id) => {
      const en = layer.sections[id]?.en;
      const ru = SECTION[id]?.title;
      return lang === "en" ? en || ru || id : ru || en || id;
    };
    // Локализованная подпись значения enum (id остаётся техническим).
    const tenum = (token) => {
      const key = typeof token === "string" ? token : String(token);
      const entry = layer.enums[key];
      if (!entry) return key;
      return entry[lang] ?? entry.ru ?? key;
    };

    return { lang, setLang: setLangPersist, t, tset, tdesc, tsec, tenum, UI };
  }, [lang, setLangPersist]);

  return <I18nContext.Provider value={api}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used within I18nProvider");
  return ctx;
}
