import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

import spec from "./settings-spec.json";
import defaultState from "./default-state.json";
import "./styles.css";

import { I18nProvider, useI18n, LANGS } from "./i18n/I18nContext.jsx";
import { SettingsRenderer, SETTING_SIM } from "./components/SettingsRenderer.jsx";
import { ListEditorModal } from "./components/ListEditors.jsx";
import { ConfirmDialog } from "./components/Modal.jsx";
import { LearningPanel } from "./components/LearningPanel.jsx";
import { HistoryPanel } from "./components/HistoryPanel.jsx";
import { DevPanel } from "./components/DevPanel.jsx";
import { SimulatorModal, SimulatorHub } from "./components/Simulators.jsx";
import { NetworkSim } from "./components/network/NetworkSim.jsx";

import { buildIndex, computeVisibility, applyResetWhenHidden } from "./services/DependencyResolver.js";
import { validateState } from "./services/ValidationService.js";
import { SettingsStorage } from "./services/SettingsStorage.js";
import { logger } from "./services/logger.js";
import { analytics } from "./services/analytics.js";
import { isSecretId } from "./services/secrets.js";
import { makeHistoryEntry, formatValue } from "./services/History.js";

const INDEX = buildIndex(spec);
const STORAGE_KEY = "ouo.settings.state.v1";

function App() {
  const { lang, setLang, t, tset, tsec, tdesc } = useI18n();

  const [values, setValues] = useState(() => {
    const saved = SettingsStorage.load();
    return saved ? { ...defaultState, ...saved } : { ...defaultState };
  });
  const [query, setQuery] = useState("");
  const [activeSection, setActiveSection] = useState(spec.sections[0]?.id);
  const [listEditor, setListEditor] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [banner, setBanner] = useState(null);
  const [learnSetting, setLearnSetting] = useState(null);
  const [showHistory, setShowHistory] = useState(false);
  const [history, setHistory] = useState([]);
  const [consoleLog, setConsoleLog] = useState([]);
  const [simKey, setSimKey] = useState(null);
  const [showSimHub, setShowSimHub] = useState(false);
  const [appMode, setAppMode] = useState("settings"); // settings | network
  const fileInputRef = useRef(null);

  const devMode = Boolean(values["developer.enabled"]);

  useEffect(() => { SettingsStorage.save(values); }, [values]);

  const visibility = useMemo(() => computeVisibility(spec, values, INDEX), [values]);
  const errors = useMemo(() => validateState(values, visibility, t), [values, visibility, t]);
  const errorCount = Object.keys(errors).length;

  // Поиск: название/описание/id/значение/enum на обоих языках.
  const sections = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return spec.sections;
    return spec.sections
      .map((section) => ({
        ...section,
        settings: section.settings.filter((s) => {
          const hay = [
            s.title, s.description, s.id, tset(s.id), tsec(section.id),
            JSON.stringify(values[s.id] ?? ""), (s.options || []).join(" ")
          ].join(" ").toLowerCase();
          return hay.includes(q);
        })
      }))
      .filter((section) => section.settings.length > 0);
  }, [query, values, lang]);

  const selected = sections.find((s) => s.id === activeSection) || sections[0] || null;

  function pushConsole(line) {
    setConsoleLog((c) => [...c.slice(-199), line]);
  }

  function updateValue(id, next) {
    const prev = values[id];
    logger.change(id, next);            // секреты маскируются
    analytics.settingChanged(id);       // секреты не трекаются
    const shown = isSecretId(id) ? "«•••»" : formatValue(prev);
    const shownNext = isSecretId(id) ? "«•••»" : formatValue(next);
    pushConsole(`SET ${id}  ${shown} → ${shownNext}`);
    setHistory((h) => [makeHistoryEntry(id, prev, next), ...h].slice(0, 200));
    setValues((current) => applyResetWhenHidden(spec, { ...current, [id]: next }, INDEX));
  }

  function flash(kind, text) {
    setBanner({ kind, text });
    setTimeout(() => setBanner(null), 3500);
  }

  function runAction(setting) {
    if (setting.ui?.requires_confirmation) { setConfirm({ setting }); return; }
    executeAction(setting);
  }
  function executeAction(setting) {
    analytics.action(setting.id);
    logger.info(`action ${setting.id}`);
    pushConsole(`ACTION ${setting.id}`);
    setConfirm(null);
    const sim = SETTING_SIM[setting.id];
    if (sim) { setSimKey(sim); return; }
    flash("info", `${t("banner.actionDone")} ${tset(setting.id)}`);
  }

  function toggleDevMode() { updateValue("developer.enabled", !devMode); }

  function handleExport() { SettingsStorage.downloadFile(values); flash("info", t("banner.exported")); }
  function handleImportClick() { fileInputRef.current?.click(); }
  function handleImportFile(e) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const parsed = SettingsStorage.parseImport(String(reader.result));
        setValues({ ...defaultState, ...parsed });
        pushConsole("IMPORT ok");
        flash("info", t("banner.imported"));
      } catch (err) {
        flash("error", `${t("banner.importError")} ${err.message}`);
      }
    };
    reader.onerror = () => flash("error", t("banner.readFail"));
    reader.readAsText(file);
  }
  function handleReset() {
    setValues({ ...defaultState });
    SettingsStorage.clear();
    setHistory([]);
    pushConsole("RESET");
    flash("info", t("banner.reset"));
  }

  function openSetting(id) {
    const s = INDEX[id];
    if (!s) return;
    const sec = spec.sections.find((x) => x.settings.some((y) => y.id === id));
    if (sec) setActiveSection(sec.id);
    setLearnSetting(s);
  }

  const isNet = appMode === "network";

  return (
    <div className={`app${learnSetting || showHistory ? " with-aside" : ""}${isNet ? " net-mode" : ""}`}>
      {!isNet && <aside className="sidebar">
        <div className="brand">
          {t("app.title")}
          <small>{spec.meta?.product}</small>
        </div>
        <input
          className="search"
          placeholder={t("search.placeholder")}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <nav>
          {sections.map((section) => {
            const errs = section.settings.filter((s) => errors[s.id]).length;
            return (
              <button
                key={section.id}
                className={selected?.id === section.id ? "nav active" : "nav"}
                onClick={() => setActiveSection(section.id)}
              >
                <span>{tsec(section.id)}</span>
                <span className="nav-meta">
                  {errs > 0 && <em className="nav-err">{errs}</em>}
                  <small>{section.settings.length}</small>
                </span>
              </button>
            );
          })}
        </nav>
        <div className={`valid-summary ${errorCount ? "bad" : "ok"}`}>
          {errorCount ? `${t("valid.errors")} ${errorCount}` : t("valid.allOk")}
        </div>
      </aside>}

      <div className="workspace">
        <header className="topbar">
          <div className="lang-toggle">
            {LANGS.map((l) => (
              <button key={l.code} className={lang === l.code ? "on" : ""} onClick={() => setLang(l.code)}>
                {l.label}
              </button>
            ))}
          </div>
          <div className="seg mode-toggle">
            <button className={!isNet ? "on" : ""} onClick={() => setAppMode("settings")}>{t("mode.settings")}</button>
            <button className={isNet ? "on" : ""} onClick={() => setAppMode("network")}>{t("mode.network")}</button>
          </div>
          <div className="spacer" />
          {!isNet && <>
            <button className="btn ghost sm" onClick={() => setShowSimHub(true)}>▶ {t("sim.hub")}</button>
            <button className="btn ghost sm" onClick={() => setShowHistory((v) => !v)}>{t("history.open")}</button>
            <button className="btn ghost sm" onClick={handleImportClick}>{t("toolbar.import")}</button>
            <button className="btn ghost sm" onClick={handleExport}>{t("toolbar.export")}</button>
            <button className="btn ghost sm" onClick={handleReset}>{t("toolbar.reset")}</button>
            <button className={`btn sm ${devMode ? "primary" : "ghost"}`} onClick={toggleDevMode}>
              {t("toolbar.developer")}
            </button>
          </>}
          <input
            ref={fileInputRef}
            type="file"
            accept="application/json,.json"
            style={{ display: "none" }}
            onChange={handleImportFile}
          />
        </header>

        {isNet ? (
          <NetworkSim />
        ) : (
        <main>
          {banner && <div className={`banner ${banner.kind}`}>{banner.text}</div>}

          <SettingsRenderer
            spec={spec}
            section={selected}
            values={values}
            visibility={visibility}
            errors={errors}
            onChange={updateValue}
            onAction={runAction}
            onOpenList={(setting) => setListEditor(setting)}
            onLearn={(setting) => setLearnSetting(setting)}
            onSimulate={(key) => setSimKey(key)}
          />

          {devMode && (
            <DevPanel
              spec={spec}
              values={values}
              visibility={visibility}
              errors={errors}
              consoleLog={consoleLog}
              onClearConsole={() => setConsoleLog([])}
              storageKey={STORAGE_KEY}
            />
          )}
        </main>
        )}
      </div>

      {(learnSetting || showHistory) && (
        <div className="aside-col">
          {showHistory && (
            <HistoryPanel
              entries={history}
              onClear={() => setHistory([])}
              onClose={() => setShowHistory(false)}
            />
          )}
          {learnSetting && (
            <LearningPanel
              spec={spec}
              setting={learnSetting}
              values={values}
              onClose={() => setLearnSetting(null)}
              onOpenSetting={openSetting}
            />
          )}
        </div>
      )}

      {listEditor && (
        <ListEditorModal
          setting={listEditor}
          value={values[listEditor.id]}
          onSave={(items) => { updateValue(listEditor.id, items); setListEditor(null); }}
          onClose={() => setListEditor(null)}
        />
      )}

      {confirm && (
        <ConfirmDialog
          title={tset(confirm.setting.id)}
          danger={Boolean(confirm.setting.ui?.danger)}
          confirmLabel={confirm.setting.ui?.danger ? t("confirm.doDanger") : t("modal.confirm")}
          message={tdesc(confirm.setting.id)}
          onConfirm={() => executeAction(confirm.setting)}
          onCancel={() => setConfirm(null)}
        />
      )}

      {simKey && <SimulatorModal simKey={simKey} values={values} onClose={() => setSimKey(null)} />}
      {showSimHub && (
        <SimulatorHub
          values={values}
          onClose={() => setShowSimHub(false)}
          onPick={(key) => { setShowSimHub(false); setSimKey(key); }}
        />
      )}
    </div>
  );
}

createRoot(document.getElementById("root")).render(
  <I18nProvider>
    <App />
  </I18nProvider>
);
