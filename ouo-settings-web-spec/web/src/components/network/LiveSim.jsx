import React, { useEffect, useMemo, useRef, useState } from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { LiveEngine } from "../../sim/liveEngine.js";
import { PRESET_IDS, DEFAULT_SCALE } from "../../sim/presets.js";
import { randomSeed } from "../../sim/rng.js";
import { formatTime } from "../../sim/engine.js";
import { NetworkCanvas } from "./NetworkCanvas.jsx";
import { InspectorPanel } from "./InspectorPanel.jsx";
import { ResourcePanel } from "./ResourcePanel.jsx";
import { LatencyPanel } from "./LatencyPanel.jsx";

const SPEEDS = [0.25, 0.5, 1, 2, 5, 10];
const FRAME_MS = 140;
const USER_COUNT_STEPS = [8, 14, 22, 30, 40];

// Категория события для фильтров журнала (§23).
function categoryOf(type) {
  if (["MEDIA_SENT", "MEDIA_UPLOADED"].includes(type)) return "media";
  if (["SYNC_DONE"].includes(type)) return "sync";
  if (["CALL_START", "CALL_END"].includes(type)) return "calls";
  if (["RESOURCE_PREEMPTED", "LOAD_SPIKE"].includes(type)) return "assist";
  if (["SCAN_REJECTED", "REPLAY_BLOCKED", "ROUTE_REVOKED", "CAPABILITY_RESTORED", "NODE_KILLED", "NODE_REVIVED",
       "CONNECTION_BLOCKED", "CONNECTION_UNBLOCKED", "DEVICE_KEY_REVOKED", "USER_ADDED", "NODE_ADDED"].includes(type)) return "security";
  return "text";
}
const FILTERS = ["text", "media", "sync", "calls", "assist", "security"];

/**
 * Живая симуляция сети OUO — масштабируемая (8–40+ пользователей) и
 * скриптуемая: добавление пользователей/нод, отзыв ключей, блокировка
 * соединений и т.д. управляются как из кнопок, так и из текстовой консоли,
 * через один и тот же публичный API LiveEngine.
 */
export function LiveSim({ simMode, onMode }) {
  const { lang, t } = useI18n();
  const engineRef = useRef(null);
  const accRef = useRef(0);
  const [seed, setSeed] = useState(48291);
  const [preset, setPreset] = useState("normal");
  const [userCount, setUserCount] = useState(DEFAULT_SCALE.userCount);
  const [scaleTick, setScaleTick] = useState(0);
  const [running, setRunning] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [snap, setSnap] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [selectedMsg, setSelectedMsg] = useState(null);
  const [filters, setFilters] = useState(() => new Set(FILTERS));
  const [rightTab, setRightTab] = useState("inspector");
  const [cmdText, setCmdText] = useState("");

  // (Ре)инициализация движка при смене seed/preset/размера сети.
  useEffect(() => {
    engineRef.current = new LiveEngine(seed, preset, { ...DEFAULT_SCALE, userCount });
    accRef.current = 0;
    setSnap(engineRef.current.snapshot());
    setSelectedId(null);
    setSelectedMsg(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seed, preset, scaleTick]);

  // Цикл симуляции.
  useEffect(() => {
    if (!running) return undefined;
    const id = setInterval(() => {
      const eng = engineRef.current;
      accRef.current += speed;
      let n = Math.floor(accRef.current);
      accRef.current -= n;
      n = Math.min(n, 14);
      for (let i = 0; i < n; i += 1) eng.tick();
      if (n > 0) setSnap(eng.snapshot());
    }, FRAME_MS);
    return () => clearInterval(id);
  }, [running, speed]);

  function step() {
    engineRef.current.tick();
    setSnap(engineRef.current.snapshot());
  }
  function reset() {
    setRunning(false);
    engineRef.current.reset(seed, preset, { ...DEFAULT_SCALE, userCount });
    accRef.current = 0;
    setSnap(engineRef.current.snapshot());
    setSelectedMsg(null);
  }
  function selectNode(id) {
    setSelectedId(id);
    setSelectedMsg(null);
  }
  function selectMarker(mk) {
    setSelectedMsg({ ...mk, status: "sent" });
    setRightTab("inspector");
  }
  function selectLogEntry(l) {
    if (!l.meta) return;
    setSelectedMsg({ ...l.meta, msgLabel: null, t: l.t });
    setSelectedId(null);
    setRightTab("inspector");
  }
  function toggleFilter(f) {
    setFilters((prev) => {
      const next = new Set(prev);
      next.has(f) ? next.delete(f) : next.add(f);
      return next;
    });
  }
  // Любое скриптовое действие: выполнить на движке, сразу обновить снимок.
  function run(fn) {
    fn(engineRef.current);
    setSnap(engineRef.current.snapshot());
  }
  function pickRandom(arr) { return arr.length ? arr[Math.floor(Math.random() * arr.length)] : null; }

  function runCommand(raw) {
    const line = raw.trim();
    if (!line) return;
    const [cmd, ...args] = line.split(/\s+/);
    run((eng) => {
      switch (cmd) {
        case "add":
          if (args[0] === "user") eng.addUser(args[1] === "home" ? true : args[1] === "nohome" ? false : null);
          else if (args[0] === "node") eng.addNode(args[1] === "s3" ? "s3" : "relay");
          else eng._emit("SCAN_REJECTED", `Неизвестная команда: ${line}`, `Unknown command: ${line}`);
          break;
        case "revoke":
          if (args[0]) eng.revokeDevice(args[0]);
          break;
        case "block":
          if (args[0] && args[1]) eng.blockPair(args[0], args[1]);
          break;
        case "unblock":
          if (args[0] === "all") eng.blockedPairs.clear();
          else if (args[0]) eng.unblockPair(args[0]);
          break;
        case "kill":
          if (args[0]) eng.killNode(args[0]);
          break;
        case "revive":
          if (args[0]) eng.reviveNode(args[0]);
          break;
        default:
          eng._emit("SCAN_REJECTED", `Неизвестная команда: ${line}`, `Unknown command: ${line}`);
      }
    });
    setCmdText("");
  }

  const state = useMemo(() => (snap ? { objects: snap.objects, edges: snap.edges } : { objects: {}, edges: [] }), [snap]);
  const selectedObj = snap && selectedId ? snap.objects[selectedId] : null;
  const focusNode = selectedObj?.kind === "home" ? selectedObj : null;
  const st = snap?.stats;
  const iconScale = userCount <= 14 ? 1 : userCount <= 24 ? 0.85 : userCount <= 32 ? 0.7 : 0.58;
  const shownLog = useMemo(() => {
    if (!snap) return [];
    return snap.log.filter((l) => filters.has(categoryOf(l.type))).slice(-60).reverse();
  }, [snap, filters]);

  const relayIds = snap ? Object.values(snap.objects).filter((o) => o.kind === "relay").map((o) => o.id) : [];
  const homeIds = snap ? snap.users.map((u) => u.homeNodeId).filter(Boolean) : [];
  const onlineCount = snap ? snap.users.filter((u) => u.devices.some((d) => snap.objects[d]?.online)).length : 0;

  if (!snap) return null;

  return (
    <div className="net-sim live">
      <div className="net-toolbar">
        {onMode && (
          <div className="seg mode-sim">
            <button className={simMode === "scenario" ? "on" : ""} onClick={() => onMode("scenario")}>{t("net.mode.scenario")}</button>
            <button className={simMode === "live" ? "on" : ""} onClick={() => onMode("live")}>{t("net.mode.live")}</button>
          </div>
        )}
        <div className="live-presets">
          {PRESET_IDS.map((pid) => (
            <button key={pid} className={`btn sm ${pid === preset ? "primary" : "ghost"}`} onClick={() => setPreset(pid)}>
              {t(`live.preset.${pid}`)}
            </button>
          ))}
        </div>
        <div className="live-scale">
          <span className="muted small">{t("live.networkSize")}</span>
          <div className="seg">
            {USER_COUNT_STEPS.map((n) => (
              <button key={n} className={userCount === n ? "on" : ""} onClick={() => setUserCount(n)}>{n}</button>
            ))}
          </div>
          <button className="btn ghost sm" onClick={() => setScaleTick((v) => v + 1)}>{t("live.rebuild")}</button>
        </div>
        <div className="spacer" />
        <div className="net-controls">
          <button className="btn ghost sm" onClick={reset}>⏮ {t("net.reset")}</button>
          <button className={`btn sm ${running ? "primary" : "ghost"}`} onClick={() => setRunning((r) => !r)}>
            {running ? `❚❚ ${t("net.pause")}` : `▶ ${t("net.play")}`}
          </button>
          <button className="btn ghost sm" disabled={running} onClick={step}>{t("live.tick")} ▶</button>
          <div className="seg">
            {SPEEDS.map((s) => (
              <button key={s} className={speed === s ? "on" : ""} onClick={() => setSpeed(s)}>{s}x</button>
            ))}
          </div>
        </div>
      </div>

      {/* header stats (§18) */}
      <div className="live-headbar">
        <span>{t("live.simTime")}: <b>{formatTime(snap.time)}</b></span>
        <span>{t("live.users")}: <b>{snap.users.length}</b> ({onlineCount} {t("live.online")})</span>
        <span>{t("live.events")}: <b>{st.created}</b></span>
        <span>{t("live.active")}: <b>{snap.transfers}{snap.aggregated ? ` (+${snap.aggregated})` : ""}</b></span>
        <span>{t("live.deliveredN")}: <b>{st.delivered}</b></span>
        <span className="live-seed">
          seed <b>{seed}</b>
          <button className="btn ghost sm" onClick={reset}>{t("live.replay")}</button>
          <button className="btn ghost sm" onClick={() => setSeed(randomSeed())}>{t("live.newSeed")}</button>
        </span>
      </div>

      <div className={`net-main${focusNode ? " with-res" : ""}`}>
        <div className="net-canvas-wrap">
          <NetworkCanvas
            state={state} viewBox="0 0 1240 960" selectedId={selectedId}
            onSelect={selectNode} onDrag={() => {}} markers={snap.markers} showMetrics
            iconScale={iconScale}
            selectedMarkerId={selectedMsg?.transferId} onSelectMarker={selectMarker}
          />
          <div className="net-hint muted small">{t("live.canvasHint")}</div>
        </div>
        {focusNode && <ResourcePanel node={focusNode} />}

        <div className="net-right">
          <div className="seg right-tabs">
            <button className={rightTab === "inspector" ? "on" : ""} onClick={() => setRightTab("inspector")}>{t("net.inspector")}</button>
            <button className={rightTab === "roster" ? "on" : ""} onClick={() => setRightTab("roster")}>{t("live.roster")}</button>
            <button className={rightTab === "console" ? "on" : ""} onClick={() => setRightTab("console")}>{t("live.console")}</button>
            <button className={rightTab === "latency" ? "on" : ""} onClick={() => setRightTab("latency")}>{t("lat.tab")}</button>
          </div>

          {rightTab === "inspector" && (
            <InspectorPanel state={state} selectedId={selectedId} currentEvent={null} users={snap.users} selectedMsg={selectedMsg} />
          )}

          {rightTab === "latency" && <LatencyPanel stats={st} />}

          {rightTab === "roster" && (
            <div className="net-roster">
              <div className="roster-stat muted small">{snap.users.length} {t("live.users")} · {homeIds.length} {t("live.withHome")}</div>
              <ul className="roster-list">
                {snap.users.map((u) => {
                  const presenceId = u.homeNodeId || u.devices[0];
                  const online = u.devices.some((d) => snap.objects[d]?.online);
                  return (
                    <li key={u.id} className={selectedId === presenceId ? "sel" : ""} onClick={() => selectNode(presenceId)}>
                      <span className={`roster-dot ${online ? "on" : "off"}`} />
                      <span className="roster-name">{u.name}</span>
                      <span className="roster-tag">{u.homeNodeId ? "🏡" : "📱"}</span>
                    </li>
                  );
                })}
              </ul>
            </div>
          )}

          {rightTab === "console" && (
            <div className="net-console">
              <p className="muted small">{t("live.consoleHint")}</p>
              <div className="console-actions">
                <button className="btn ghost sm" onClick={() => run((e) => e.addUser(true))}>+ {t("live.userWithHome")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => e.addUser(false))}>+ {t("live.userNoHome")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => e.addNode("relay"))}>+ {t("live.addRelay")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => e.addNode("s3"))}>+ {t("live.addS3")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => { const id = pickRandom(relayIds); if (id) e.killNode(id); })}>{t("live.killRelay")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => { const id = pickRandom(homeIds); if (id) e.killNode(id); })}>{t("live.killHome")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => {
                  const ids = relayIds.concat(homeIds);
                  const [a, b] = [pickRandom(ids), pickRandom(ids)];
                  if (a && b && a !== b) e.blockPair(a, b);
                })}>{t("live.blockRandom")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => e.blockedPairs.clear())}>{t("live.unblockAll")}</button>
                <button className="btn ghost sm" onClick={() => run((e) => { relayIds.concat(homeIds).forEach((id) => e.reviveNode(id)); })}>{t("live.reviveAll")}</button>
              </div>

              {snap.blockedPairs.length > 0 && (
                <div className="console-blocked">
                  <h5>{t("live.blockedPairs")}</h5>
                  <ul>
                    {snap.blockedPairs.map((k) => (
                      <li key={k}><code>{k}</code><button className="btn ghost sm" onClick={() => run((e) => e.unblockPair(k))}>✕</button></li>
                    ))}
                  </ul>
                </div>
              )}

              <form className="console-input" onSubmit={(e) => { e.preventDefault(); runCommand(cmdText); }}>
                <input type="text" value={cmdText} placeholder="add user home | revoke phone-3 | block home-1 relay-2 | kill relay-1"
                  onChange={(e) => setCmdText(e.target.value)} />
                <button className="btn primary sm" type="submit">{t("live.run")}</button>
              </form>
              <p className="console-ref muted small">
                add user [home|nohome] · add node [relay|s3] · revoke &lt;deviceId&gt; ·
                block/unblock &lt;a&gt; &lt;b&gt; · kill/revive &lt;id&gt;
              </p>
            </div>
          )}
        </div>
      </div>

      {/* dashboard + log */}
      <div className="live-bottom">
        <div className="live-dash">
          <div className="dash-card">
            <h5>{t("live.d.messages")}</h5>
            <ul>
              <li><span>{t("live.d.created")}</span><b>{st.created}</b></li>
              <li><span>{t("live.d.delivered")}</span><b>{st.delivered}</b></li>
              <li><span>{t("live.d.waiting")}</span><b>{st.waiting}</b></li>
            </ul>
          </div>
          <div className="dash-card">
            <h5>{t("live.d.media")}</h5>
            <ul>
              <li><span>{t("live.d.uploaded")}</span><b>{st.mediaUp}</b></li>
              <li><span>{t("live.d.downloaded")}</span><b>{st.mediaDown}</b></li>
              <li><span>{t("live.d.replicated")}</span><b>{st.replicated}</b></li>
            </ul>
          </div>
          <div className="dash-card">
            <h5>{t("live.d.routes")}</h5>
            <ul>
              <li><span>direct</span><b>{st.routes.DIRECT}</b></li>
              <li><span>relay</span><b>{st.routes.RELAY}</b></li>
              <li><span>S3</span><b>{st.routes.S3_FALLBACK}</b></li>
              <li><span>queue</span><b>{st.routes.HOME_STORAGE + st.routes.LOCAL_QUEUE}</b></li>
            </ul>
          </div>
          <div className="dash-card">
            <h5>{t("live.d.security")}</h5>
            <ul>
              <li><span>{t("live.d.scans")}</span><b>{st.security.scans}</b></li>
              <li><span>{t("live.d.replays")}</span><b>{st.security.replays}</b></li>
              <li><span>{t("live.d.revocations")}</span><b>{st.security.revocations}</b></li>
              <li><span>{t("live.d.calls")}</span><b>{st.calls}</b></li>
            </ul>
          </div>
        </div>

        <div className="live-log">
          <div className="live-log-head">
            <span>{t("live.log")}</span>
            <div className="live-filters">
              {FILTERS.map((f) => (
                <button key={f} className={`chip sm ${filters.has(f) ? "active" : ""}`} onClick={() => toggleFilter(f)}>{t(`live.f.${f}`)}</button>
              ))}
            </div>
          </div>
          <ol className="live-log-list">
            {shownLog.map((l) => (
              <li key={l.id} className={`ll ${categoryOf(l.type)}${l.meta ? " clickable" : ""}`}
                onClick={() => selectLogEntry(l)}>
                <time>{formatTime(l.t)}</time>
                <code>{l.type}</code>
                <span>{l.text[lang] ?? l.text.ru}</span>
              </li>
            ))}
          </ol>
        </div>
      </div>
    </div>
  );
}
