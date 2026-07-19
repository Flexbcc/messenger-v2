import React, { useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { SCENARIOS } from "../../sim/scenarios.js";
import { SECURITY_SCENARIOS } from "../../sim/securityScenarios.js";
import { LIFECYCLE_SCENARIOS } from "../../sim/lifecycleScenarios.js";
import { buildState } from "../../sim/engine.js";
import { NetworkCanvas } from "./NetworkCanvas.jsx";
import { EventTimeline } from "./EventTimeline.jsx";
import { InspectorPanel } from "./InspectorPanel.jsx";
import { ResourcePanel } from "./ResourcePanel.jsx";
import { LatencyPanel } from "./LatencyPanel.jsx";
import { LiveSim } from "./LiveSim.jsx";

function ModeToggle({ simMode, onMode }) {
  const { t } = useI18n();
  return (
    <div className="seg mode-sim">
      <button className={simMode === "scenario" ? "on" : ""} onClick={() => onMode("scenario")}>{t("net.mode.scenario")}</button>
      <button className={simMode === "live" ? "on" : ""} onClick={() => onMode("live")}>{t("net.mode.live")}</button>
    </div>
  );
}

const SPEEDS = [1, 2, 5, 10];
const CATEGORIES = {
  network: SCENARIOS,
  security: SECURITY_SCENARIOS,
  lifecycle: LIFECYCLE_SCENARIOS
};
const VIEW_MODES = ["simple", "technical", "threat", "resource"];

/**
 * OUO Network Simulation Canvas — общий шелл визуализатора.
 * Две категории сценариев в одной оболочке (п.4/27 ТЗ): «Сеть OUO» и
 * «Безопасность OUO Home». Пошаговая воспроизводимая симуляция: состояние
 * строится фолдингом events[0..cursor].
 */
export function NetworkSim() {
  const { lang, t } = useI18n();
  const [category, setCategory] = useState("network");
  const list = CATEGORIES[category];
  const [scenarioId, setScenarioId] = useState(list[0].id);
  const [cursor, setCursor] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [selectedId, setSelectedId] = useState(null);
  const [rightTab, setRightTab] = useState("inspector");
  const [viewMode, setViewMode] = useState("simple");
  const [offsets, setOffsets] = useState({});
  const [simMode, setSimMode] = useState("scenario");
  const timerRef = useRef(null);

  const scenario = list.find((s) => s.id === scenarioId) || list[0];
  const events = scenario.events;

  const baseState = useMemo(() => buildState(events, cursor), [events, cursor]);

  const state = useMemo(() => {
    const objects = { ...baseState.objects };
    for (const [id, pos] of Object.entries(offsets)) {
      if (objects[id]) objects[id] = { ...objects[id], x: pos.x, y: pos.y };
    }
    return { ...baseState, objects };
  }, [baseState, offsets]);

  useEffect(() => {
    if (!playing) return undefined;
    timerRef.current = setInterval(() => {
      setCursor((c) => {
        if (c >= events.length - 1) { setPlaying(false); return c; }
        return c + 1;
      });
    }, 900 / speed);
    return () => clearInterval(timerRef.current);
  }, [playing, speed, events.length]);

  function selectScenario(id) {
    setScenarioId(id);
    setCursor(0);
    setPlaying(false);
    setSelectedId(null);
    setOffsets({});
  }
  function selectCategory(cat) {
    setCategory(cat);
    const first = CATEGORIES[cat][0];
    setScenarioId(first.id);
    setCursor(0);
    setPlaying(false);
    setSelectedId(null);
    setOffsets({});
    if (cat === "security") setViewMode("resource");
  }

  const currentEvent = events[cursor] || null;
  const showResPanel = category === "security" || category === "lifecycle";
  const showMetrics = viewMode === "resource" || viewMode === "threat";
  const focusNode = scenario.focus ? state.objects[scenario.focus] : null;

  if (simMode === "live") return <LiveSim simMode={simMode} onMode={setSimMode} />;

  return (
    <div className="net-sim">
      <div className="net-toolbar">
        <ModeToggle simMode={simMode} onMode={setSimMode} />
        <div className="seg cat-toggle">
          <button className={category === "network" ? "on" : ""} onClick={() => selectCategory("network")}>{t("net.cat.network")}</button>
          <button className={category === "security" ? "on" : ""} onClick={() => selectCategory("security")}>{t("net.cat.security")}</button>
          <button className={category === "lifecycle" ? "on" : ""} onClick={() => selectCategory("lifecycle")}>{t("net.cat.lifecycle")}</button>
        </div>
        <div className="net-scenarios">
          {list.map((s, i) => (
            <button key={s.id}
              className={`btn sm ${s.id === scenarioId ? "primary" : "ghost"}`}
              onClick={() => selectScenario(s.id)}>
              {i + 1}. {s.title[lang] ?? s.title.ru}
            </button>
          ))}
        </div>
        <div className="spacer" />
        <div className="net-controls">
          <div className="seg view-toggle">
            {VIEW_MODES.map((v) => (
              <button key={v} className={viewMode === v ? "on" : ""} onClick={() => setViewMode(v)}>{t(`net.view.${v}`)}</button>
            ))}
          </div>
          <button className="btn ghost sm" onClick={() => { setCursor(0); setPlaying(false); }}>⏮ {t("net.reset")}</button>
          <button className="btn ghost sm" disabled={cursor <= 0} onClick={() => setCursor((c) => Math.max(0, c - 1))}>◀ {t("net.prev")}</button>
          <button className={`btn sm ${playing ? "primary" : "ghost"}`} onClick={() => setPlaying((p) => !p)}>
            {playing ? `❚❚ ${t("net.pause")}` : `▶ ${t("net.play")}`}
          </button>
          <button className="btn ghost sm" disabled={cursor >= events.length - 1} onClick={() => setCursor((c) => Math.min(events.length - 1, c + 1))}>{t("net.step")} ▶</button>
          <div className="seg">
            {SPEEDS.map((s) => (
              <button key={s} className={speed === s ? "on" : ""} onClick={() => setSpeed(s)}>x{s}</button>
            ))}
          </div>
        </div>
      </div>

      <div className={`net-main${showResPanel ? " with-res" : ""}`}>
        <div className="net-canvas-wrap">
          <NetworkCanvas
            state={state}
            viewBox={scenario.viewBox}
            selectedId={selectedId}
            onSelect={setSelectedId}
            onDrag={(id, x, y) => setOffsets((o) => ({ ...o, [id]: { x, y } }))}
            showMetrics={showMetrics}
          />
          <div className="net-hint muted small">{t("net.dragHint")}</div>
        </div>
        {showResPanel && <ResourcePanel node={focusNode} />}

        <div className="net-right">
          <div className="seg right-tabs">
            <button className={rightTab === "inspector" ? "on" : ""} onClick={() => setRightTab("inspector")}>{t("net.inspector")}</button>
            <button className={rightTab === "latency" ? "on" : ""} onClick={() => setRightTab("latency")}>{t("lat.tab")}</button>
          </div>
          {rightTab === "inspector" && (
            <InspectorPanel state={state} selectedId={selectedId} currentEvent={currentEvent} />
          )}
          {rightTab === "latency" && <LatencyPanel />}
        </div>
      </div>

      <EventTimeline events={events} cursor={cursor} onJump={(i) => { setCursor(i); setPlaying(false); }} />
    </div>
  );
}
