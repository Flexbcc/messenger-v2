import React from "react";
import { useI18n } from "../i18n/I18nContext.jsx";
import { formatValue } from "../services/History.js";

/** Панель истории изменений: что, когда, старое → новое значение. */
export function HistoryPanel({ entries, onClear, onClose }) {
  const { t, tset } = useI18n();
  return (
    <aside className="history-panel">
      <header className="learn-head">
        <h3>{t("history.title")}</h3>
        <div className="row-end">
          <button className="btn ghost sm" onClick={onClear}>{t("history.clear")}</button>
          <button className="icon-btn" onClick={onClose} aria-label={t("modal.close")}>✕</button>
        </div>
      </header>
      <div className="history-body">
        {entries.length === 0 ? (
          <p className="muted small">{t("history.empty")}</p>
        ) : (
          <ul className="history-list">
            {entries.map((e) => (
              <li key={e.seq}>
                <div className="history-top">
                  <strong>{tset(e.id)}</strong>
                  <time>{new Date(e.ts).toLocaleTimeString()}</time>
                </div>
                <code className="history-id">{e.id}</code>
                <div className="history-diff">
                  <span className="old">{t("history.was")}: {formatValue(e.old)}</span>
                  <span className="arrow">→</span>
                  <span className="new">{t("history.now")}: {formatValue(e.next)}</span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </aside>
  );
}
