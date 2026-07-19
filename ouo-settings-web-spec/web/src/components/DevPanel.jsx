import React, { useState } from "react";
import { useI18n } from "../i18n/I18nContext.jsx";
import { redactSecrets } from "../services/secrets.js";

const TABS = ["json", "state", "deps", "validation", "storage", "console"];

/**
 * Инструменты разработчика. Секреты в JSON/State замаскированы.
 */
export function DevPanel({ spec, values, visibility, errors, consoleLog, onClearConsole, storageKey }) {
  const { t, tset } = useI18n();
  const [tab, setTab] = useState("json");

  const safe = redactSecrets(values);
  const visibleIds = Object.keys(values).filter((id) => visibility[id] !== false);
  const hiddenIds = Object.keys(values).filter((id) => visibility[id] === false);

  const depSettings = [];
  for (const section of spec.sections) {
    for (const s of section.settings) {
      if (s.visible_if) depSettings.push(s);
    }
  }

  return (
    <div className="dev-panel">
      <div className="dev-tabs">
        {TABS.map((k) => (
          <button key={k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>
            {t(`dev.tab.${k}`)}
          </button>
        ))}
      </div>

      <div className="dev-content">
        {tab === "json" && <pre className="code">{JSON.stringify(safe, null, 2)}</pre>}

        {tab === "state" && (
          <div>
            <div className="dev-stat">
              <span>{visibleIds.length} {t("dev.state.visible")}</span>
              <span>{hiddenIds.length} {t("dev.state.hidden")}</span>
            </div>
            <pre className="code">{JSON.stringify(safe, null, 2)}</pre>
          </div>
        )}

        {tab === "deps" && (
          <div>
            <p className="muted small">{t("dev.deps.hint")}</p>
            <ul className="dev-list">
              {depSettings.map((s) => {
                const shown = visibility[s.id] !== false;
                const cond = s.visible_if;
                const kind = "equals" in cond ? `= ${JSON.stringify(cond.equals)}` : `∈ ${JSON.stringify(cond.in)}`;
                return (
                  <li key={s.id}>
                    <code>{s.id}</code>
                    <span className="dep-cond">{cond.setting} {kind}</span>
                    <span className={shown ? "pill ok" : "pill off"}>
                      {shown ? t("dev.deps.shown") : t("dev.deps.hiddenState")}
                    </span>
                  </li>
                );
              })}
            </ul>
          </div>
        )}

        {tab === "validation" && (
          <div>
            {Object.keys(errors).length === 0 ? (
              <div className="result ok">{t("dev.validation.clean")}</div>
            ) : (
              <ul className="dev-list">
                {Object.entries(errors).map(([id, msg]) => (
                  <li key={id}>
                    <code>{id}</code>
                    <span className="dep-cond">{tset(id)}</span>
                    <span className="err-msg">{msg}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {tab === "storage" && (
          <div>
            <p className="muted small">{t("dev.storage.key")}: <code>{storageKey}</code></p>
            <pre className="code">{JSON.stringify(safe, null, 2)}</pre>
          </div>
        )}

        {tab === "console" && (
          <div>
            <div className="dev-stat">
              <button className="btn ghost sm" onClick={onClearConsole}>{t("dev.console.clear")}</button>
            </div>
            {consoleLog.length === 0 ? (
              <div className="muted small">{t("dev.console.empty")}</div>
            ) : (
              <pre className="code console">
                {consoleLog.map((l, i) => `${l}\n`).join("")}
              </pre>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
