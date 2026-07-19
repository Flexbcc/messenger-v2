import React, { useState } from "react";
import { useI18n } from "../i18n/I18nContext.jsx";

function normalizeOption(option) {
  return typeof option === "string" ? option : String(option);
}

/**
 * Рендерит управляющий элемент под конкретный тип настройки.
 * Значения приходят/уходят через value/onChange, чтобы состоянием
 * владел SettingsRenderer (единый источник данных из спеки).
 *
 * Типы: boolean, single_select, multi_select, text, number, secret,
 *       read_only, action, list.
 */
export function SettingControl({
  setting,
  value,
  onChange,
  onAction,
  onOpenList,
  systemValue
}) {
  const type = setting.type;
  const { t, tenum } = useI18n();
  const [reveal, setReveal] = useState(false);

  if (type === "boolean") {
    return (
      <label className="switch">
        <input
          type="checkbox"
          checked={Boolean(value)}
          onChange={(e) => onChange(e.target.checked)}
        />
        <span />
      </label>
    );
  }

  if (type === "single_select") {
    const sample = setting.options?.[0];
    const isNumeric = typeof sample === "number";
    return (
      <select
        value={value ?? ""}
        onChange={(e) => onChange(isNumeric ? Number(e.target.value) : e.target.value)}
      >
        {(setting.options || []).map((option) => (
          <option key={normalizeOption(option)} value={option}>
            {tenum(option)}
          </option>
        ))}
      </select>
    );
  }

  if (type === "multi_select") {
    const selected = Array.isArray(value) ? value : [];
    return (
      <div className="chips">
        {(setting.options || []).map((option) => {
          const active = selected.includes(option);
          return (
            <button
              type="button"
              key={normalizeOption(option)}
              className={active ? "chip active" : "chip"}
              onClick={() =>
                onChange(
                  active
                    ? selected.filter((x) => x !== option)
                    : [...selected, option]
                )
              }
            >
              {tenum(option)}
            </button>
          );
        })}
      </div>
    );
  }

  if (type === "number") {
    return (
      <input
        type="number"
        value={value ?? ""}
        min={setting.data?.minimum}
        max={setting.data?.maximum}
        onChange={(e) =>
          onChange(e.target.value === "" ? "" : Number(e.target.value))
        }
      />
    );
  }

  if (type === "text") {
    const common = {
      value: value ?? "",
      maxLength: setting.data?.maxLength,
      placeholder: setting.ui?.placeholder || "",
      onChange: (e) => onChange(e.target.value)
    };
    return setting.ui?.control === "textarea" || setting.multiline ? (
      <textarea {...common} rows={3} />
    ) : (
      <input {...common} type="text" />
    );
  }

  if (type === "secret") {
    // Секрет: показываем поле пароля, значение не отображаем в открытом виде
    // по умолчанию и не логируем (см. logger/analytics).
    return (
      <div className="secret-field">
        <input
          type={reveal ? "text" : "password"}
          value={value ?? ""}
          maxLength={setting.data?.maxLength}
          autoComplete="new-password"
          placeholder="••••"
          onChange={(e) => onChange(e.target.value)}
        />
        <button
          type="button"
          className="btn ghost sm"
          onClick={() => setReveal((r) => !r)}
        >
          {reveal ? t("control.hide") : t("control.show")}
        </button>
      </div>
    );
  }

  if (type === "read_only") {
    const display =
      systemValue === undefined || systemValue === null || systemValue === ""
        ? "—"
        : String(systemValue);
    return <span className="readonly-value">{display}</span>;
  }

  if (type === "action") {
    const danger = Boolean(setting.ui?.danger);
    return (
      <button
        type="button"
        className={`btn ${danger ? "danger" : "primary"}`}
        onClick={() => onAction(setting)}
      >
        {danger ? "⚠ " : ""}
        {t("control.run")}
      </button>
    );
  }

  if (type === "list") {
    const count = Array.isArray(value) ? value.length : 0;
    return (
      <div className="list-control">
        <span className="badge">{count} {t("control.items")}</span>
        <button type="button" className="btn ghost" onClick={() => onOpenList(setting)}>
          {t("control.openEditor")}
        </button>
      </div>
    );
  }

  return <span className="readonly-value">Системное значение</span>;
}
