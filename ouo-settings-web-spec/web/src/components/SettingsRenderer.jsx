import React from "react";
import { SettingControl } from "./SettingControl.jsx";
import { StorageOwnershipPanel } from "./StorageOwnershipPanel.jsx";
import { SYSTEM_VALUES } from "../services/systemState.js";
import { useI18n } from "../i18n/I18nContext.jsx";
import { learnFor } from "../content/learn.js";

// Действия/настройки, которые открывают конкретный симулятор.
export const SETTING_SIM = {
  "developer.test_notifications": "notifications",
  "developer.test_crypto": "encryption",
  "storage.route_audit": "message_routing",
  "storage.integrity_check": "replication",
  "profile.qr": "qr",
  "backup.create_now": "backup",
  "notifications.enabled": "notifications",
  "notifications.preview": "notifications",
  "security.pin_enabled": "pin",
  "security.fake_pin_enabled": "fake_pin",
  "storage.message_location": "message_routing",
  "storage.replication_factor": "replication",
  "privacy.qr_mode": "qr",
  "backup.enabled": "backup",
  "hidden.enabled": "hidden_chats"
};

/** Одна строка настройки. Всё содержимое локализуется. */
function SettingRow({ setting, value, error, onChange, onAction, onOpenList, onLearn, onSimulate }) {
  const { t, tset, tdesc } = useI18n();
  const danger = Boolean(setting.ui?.danger);
  const confirm = Boolean(setting.ui?.requires_confirmation);
  const hasLearn = Boolean(learnFor(setting.id));
  const sim = SETTING_SIM[setting.id];

  return (
    <section className={`setting${danger ? " danger" : ""}`}>
      <div className="meta">
        <div className="title-row">
          <h2>{tset(setting.id)}</h2>
          <code className="type-tag">{setting.type}</code>
          {danger && <span className="danger-badge">{t("badge.danger")}</span>}
          {confirm && <span className="confirm-badge">{t("badge.confirm")}</span>}
          {setting.required && <span className="req-badge">{t("badge.required")}</span>}
          {setting.type === "secret" && <span className="secret-badge">{t("badge.secret")}</span>}
        </div>
        <p className="desc">{tdesc(setting.id)}</p>
        <div className="technical">
          <span>{setting.id}</span>
          {setting.data?.pattern && <span>regex: {setting.data.pattern}</span>}
          {setting.data?.minLength != null && <span>minLen: {setting.data.minLength}</span>}
          {setting.data?.maxLength != null && <span>maxLen: {setting.data.maxLength}</span>}
          {setting.data?.minimum != null && <span>min: {setting.data.minimum}</span>}
          {setting.data?.maximum != null && <span>max: {setting.data.maximum}</span>}
          {setting.item_type && <span>item: {setting.item_type}</span>}
        </div>
        <div className="row-actions">
          {hasLearn && (
            <button className="link-btn" onClick={() => onLearn(setting)}>ⓘ {t("control.howItWorks")}</button>
          )}
          {sim && (
            <button className="link-btn" onClick={() => onSimulate(sim)}>▶ {t("control.simulate")}</button>
          )}
        </div>
      </div>
      <div className="control">
        <SettingControl
          setting={setting}
          value={value}
          onChange={onChange}
          onAction={onAction}
          onOpenList={onOpenList}
          systemValue={SYSTEM_VALUES[setting.id]}
        />
        {error && <div className="field-error">{error}</div>}
      </div>
    </section>
  );
}

/**
 * SettingsRenderer — строит раздел целиком из спеки (без хардкода списка).
 */
export function SettingsRenderer({
  spec, section, values, visibility, errors,
  onChange, onAction, onOpenList, onLearn, onSimulate
}) {
  const { t, tsec } = useI18n();
  if (!section) return <div className="empty">{t("search.empty")}</div>;

  const visibleSettings = section.settings.filter((s) => visibility[s.id] !== false);
  const normal = visibleSettings.filter((s) => !s.ui?.danger);
  const dangerous = visibleSettings.filter((s) => s.ui?.danger);

  const renderRow = (setting) => (
    <SettingRow
      key={setting.id}
      setting={setting}
      value={values[setting.id]}
      error={errors[setting.id]}
      onChange={(v) => onChange(setting.id, v)}
      onAction={onAction}
      onOpenList={onOpenList}
      onLearn={onLearn}
      onSimulate={onSimulate}
    />
  );

  return (
    <>
      <header className="section-head">
        <h1>{tsec(section.id)}</h1>
        <p>{visibleSettings.length} {t("section.visibleOf")} {section.settings.length} {t("section.count")}</p>
      </header>

      {section.id === "storage_ownership" && <StorageOwnershipPanel values={values} />}

      <div className="settings">{normal.map(renderRow)}</div>

      {dangerous.length > 0 && (
        <div className="danger-zone">
          <div className="danger-zone-head">
            ⚠ {t("danger.zoneTitle")}
            <small>{t("danger.zoneSub")}</small>
          </div>
          <div className="settings">{dangerous.map(renderRow)}</div>
        </div>
      )}
    </>
  );
}
