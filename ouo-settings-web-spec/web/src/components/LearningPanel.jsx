import React from "react";
import { useI18n } from "../i18n/I18nContext.jsx";
import { learnFor, COMPONENTS } from "../content/learn.js";
import { FlowDiagram } from "./Diagrams.jsx";

// Находит зависимые настройки (у кого visible_if.setting === id).
function dependents(spec, id) {
  const out = [];
  for (const section of spec.sections) {
    for (const s of section.settings) {
      if (s.visible_if?.setting === id) out.push(s.id);
    }
  }
  return out;
}

/**
 * Боковая панель «Как это работает?»: что делает настройка, какие компоненты
 * затрагивает, риски/преимущества, зависимые настройки, схема и сценарии.
 */
export function LearningPanel({ spec, setting, values, onClose, onOpenSetting }) {
  const { lang, t, tset, tdesc, tenum } = useI18n();
  const info = learnFor(setting.id);
  const deps = dependents(spec, setting.id);

  const pick = (obj) => (obj ? obj[lang] ?? obj.ru : "");

  return (
    <aside className="learn-panel">
      <header className="learn-head">
        <div>
          <h3>{tset(setting.id)}</h3>
          <code>{setting.id}</code>
        </div>
        <button className="icon-btn" onClick={onClose} aria-label={t("modal.close")}>✕</button>
      </header>

      <div className="learn-body">
        <section>
          <h4>{t("learn.what")}</h4>
          <p>{info ? pick(info.what) : tdesc(setting.id)}</p>
          {!info && <p className="muted small">{t("learn.noContent")}</p>}
        </section>

        {info?.components?.length > 0 && (
          <section>
            <h4>{t("learn.components")}</h4>
            <div className="comp-row">
              {info.components.map((c) => (
                <span className="comp-chip" key={c}>
                  {(COMPONENTS[c] && COMPONENTS[c][lang]) || c}
                </span>
              ))}
            </div>
          </section>
        )}

        {info?.diagram && (
          <section>
            <h4>{t("learn.diagram")}</h4>
            <FlowDiagram kind={info.diagram} values={values} />
          </section>
        )}

        {info && (
          <section className="tradeoffs">
            <h4>{t("learn.tradeoffs")}</h4>
            <div className="tradeoff-grid">
              <div>
                <h5 className="pros">{t("learn.pros")}</h5>
                <ul>{info.pros.map((p, i) => <li key={i}>{pick(p)}</li>)}</ul>
              </div>
              <div>
                <h5 className="cons">{t("learn.cons")}</h5>
                <ul>{info.cons.map((p, i) => <li key={i}>{pick(p)}</li>)}</ul>
              </div>
            </div>
          </section>
        )}

        {deps.length > 0 && (
          <section>
            <h4>{t("learn.deps")}</h4>
            <ul className="dep-list">
              {deps.map((d) => (
                <li key={d}>
                  <button className="link" onClick={() => onOpenSetting?.(d)}>{tset(d)}</button>
                  <code>{d}</code>
                </li>
              ))}
            </ul>
          </section>
        )}

        {info?.scenarios?.length > 0 && (
          <section>
            <h4>{t("learn.scenarios")}</h4>
            <ul className="scenario-list">
              {info.scenarios.map((s, i) => <li key={i}>{pick(s)}</li>)}
            </ul>
          </section>
        )}
      </div>
    </aside>
  );
}
