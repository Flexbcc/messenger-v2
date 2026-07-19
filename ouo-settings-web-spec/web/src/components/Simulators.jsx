import React, { useEffect, useMemo, useState } from "react";
import { useI18n } from "../i18n/I18nContext.jsx";
import { Modal } from "./Modal.jsx";
import { FlowDiagram } from "./Diagrams.jsx";

/* ─────────── Notifications ─────────── */
function NotificationSim({ values }) {
  const { t, tenum } = useI18n();
  const [scenario, setScenario] = useState("normal"); // normal | hidden
  const [result, setResult] = useState(null);

  function run() {
    if (!values["notifications.enabled"]) {
      setResult({ kind: "off" });
      return;
    }
    if (values["notifications.dnd_enabled"]) {
      setResult({ kind: "dnd" });
      return;
    }
    const preview = values["notifications.preview"]; // full | sender_only | hidden
    const hiddenPolicy = values["notifications.hidden_chat_policy"]; // none | generic | ...
    if (scenario === "hidden") {
      // Скрытый чат: защищённый вид без содержимого, независимо от preview.
      void hiddenPolicy;
      setResult({ kind: "hidden", title: t("sim.notif.protected"), body: "" });
      return;
    }
    if (preview === "hidden") {
      setResult({ kind: "banner", title: t("sim.notif.newMessage"), app: "OUO Messenger", body: "" });
    } else if (preview === "sender_only") {
      setResult({ kind: "banner", title: t("sim.notif.sample.name"), body: "" });
    } else {
      setResult({ kind: "banner", title: t("sim.notif.sample.name"), body: t("sim.notif.sample.text") });
    }
  }

  return (
    <div className="sim">
      <div className="sim-controls">
        <div className="seg">
          <button className={scenario === "normal" ? "on" : ""} onClick={() => setScenario("normal")}>
            {tenum("direct")}
          </button>
          <button className={scenario === "hidden" ? "on" : ""} onClick={() => setScenario("hidden")}>
            {tenum("hidden_chats")}
          </button>
        </div>
        <button className="btn primary" onClick={run}>{t("sim.run")}</button>
      </div>
      <div className="phone">
        <div className="phone-screen">
          {!result && <div className="muted phone-hint">···</div>}
          {result?.kind === "off" && <div className="notif-note">{t("sim.notif.disabled")}</div>}
          {result?.kind === "dnd" && <div className="notif-note">{t("sim.notif.dnd")}</div>}
          {(result?.kind === "banner" || result?.kind === "hidden") && (
            <div className="notif-banner">
              <div className="notif-app">OUO Messenger</div>
              <div className="notif-title">{result.title}</div>
              {result.body ? <div className="notif-body">{result.body}</div> : null}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/* ─────────── PIN / Fake PIN ─────────── */
function PinSim({ values }) {
  const { t } = useI18n();
  const [entry, setEntry] = useState("");
  const [attempts, setAttempts] = useState(0);
  const [result, setResult] = useState(null);
  const [lockUntil, setLockUntil] = useState(0);
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    if (!lockUntil) return;
    const id = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(id);
  }, [lockUntil]);

  const locked = lockUntil > now;
  const remaining = Math.max(0, Math.ceil((lockUntil - now) / 1000));
  const wipeAfter = Number(values["security.wipe_after"] ?? 10);

  function check() {
    if (!values["security.pin_enabled"]) { setResult({ kind: "disabled" }); return; }
    if (locked) return;
    const pin = values["security.pin"];
    const fake = values["security.fake_pin"];
    if (pin && entry === pin) { setResult({ kind: "ok" }); setAttempts(0); setEntry(""); return; }
    if (values["security.fake_pin_enabled"] && fake && entry === fake) { setResult({ kind: "fake" }); setEntry(""); return; }
    const next = attempts + 1;
    setAttempts(next);
    setEntry("");
    if (values["security.wipe_enabled"] && next >= wipeAfter) { setResult({ kind: "wipe" }); return; }
    if (next >= 5) {
      const backoff = Math.min(300, (next - 4) * 30); // 30с, 60с, …
      setLockUntil(Date.now() + backoff * 1000);
      setResult({ kind: "locked", backoff });
      return;
    }
    setResult({ kind: "wrong" });
  }

  return (
    <div className="sim">
      {!values["security.pin_enabled"] ? (
        <div className="notif-note">{t("sim.pin.disabled")}</div>
      ) : (
        <>
          <div className="pin-row">
            <input
              className="pin-input"
              type="password"
              inputMode="numeric"
              value={entry}
              placeholder="••••"
              disabled={locked}
              onChange={(e) => setEntry(e.target.value)}
            />
            <button className="btn primary" onClick={check} disabled={locked}>{t("sim.pin.check")}</button>
          </div>
          <div className="pin-status">
            <span>{t("sim.pin.attempt")} {attempts} {t("sim.pin.of")} {wipeAfter}</span>
            {locked && <span className="danger-text">{t("sim.pin.locked")} {remaining}{t("sim.pin.sec")}</span>}
          </div>
          {result?.kind === "ok" && <div className="result ok">{t("sim.pin.correct")}</div>}
          {result?.kind === "fake" && <div className="result warn">{t("sim.pin.fake")}</div>}
          {result?.kind === "wrong" && <div className="result bad">{t("sim.pin.wrong")}</div>}
          {result?.kind === "locked" && <div className="result bad">{t("sim.pin.locked")} {result.backoff}{t("sim.pin.sec")}</div>}
          {result?.kind === "wipe" && <div className="result bad">{t("sim.pin.wipeWarn")}</div>}
        </>
      )}
    </div>
  );
}

/* ─────────── Simple diagram-based simulators ─────────── */
function DiagramSim({ kind, values }) {
  return <div className="sim"><FlowDiagram kind={kind} values={values} /></div>;
}

function ReplicationSim({ values }) {
  const { t } = useI18n();
  const factor = Number(values["storage.replication_factor"] ?? 1);
  return (
    <div className="sim">
      <div className="sim-note">{factor} {t("sim.repl.replicas")}</div>
      <FlowDiagram kind="replication" values={values} />
    </div>
  );
}

/* ─────────── QR ─────────── */
function fakeQr(seed) {
  // Детерминированная сетка 21x21 из seed — визуальная имитация QR.
  const n = 21;
  let h = 0;
  for (let i = 0; i < seed.length; i += 1) h = (h * 31 + seed.charCodeAt(i)) >>> 0;
  const cells = [];
  for (let i = 0; i < n * n; i += 1) {
    h = (h * 1103515245 + 12345) & 0x7fffffff;
    cells.push(h % 3 === 0);
  }
  // финдеры по углам
  const finder = (r, c) => (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7);
  return { n, cells, finder };
}

function QrSim({ values }) {
  const { t } = useI18n();
  const mode = values["privacy.qr_mode"]; // permanent | temporary | single_use
  const ttlMin = Number(values["privacy.qr_ttl_minutes"] ?? 30);
  const [left, setLeft] = useState(ttlMin * 60);

  useEffect(() => {
    setLeft(ttlMin * 60);
    if (mode !== "temporary") return;
    const id = setInterval(() => setLeft((v) => Math.max(0, v - 1)), 1000);
    return () => clearInterval(id);
  }, [mode, ttlMin]);

  const { n, cells, finder } = useMemo(() => fakeQr(`ouo:${mode}:${ttlMin}`), [mode, ttlMin]);
  const mm = String(Math.floor(left / 60)).padStart(2, "0");
  const ss = String(left % 60).padStart(2, "0");

  return (
    <div className="sim qr-sim">
      <svg viewBox={`0 0 ${n} ${n}`} className="qr-svg" role="img">
        <rect x="0" y="0" width={n} height={n} fill="#fff" />
        {cells.map((on, i) => {
          const r = Math.floor(i / n), c = i % n;
          if (!(on || finder(r, c))) return null;
          return <rect key={i} x={c} y={r} width="1" height="1" fill="#111" />;
        })}
      </svg>
      <div className="qr-meta">
        <span className="badge">{mode === "temporary" ? t("sim.qr.temporary") : (mode === "permanent" ? t("sim.qr.permanent") : "single_use")}</span>
        {mode === "temporary" && (
          left > 0 ? <span>{t("sim.qr.expiresIn")} {mm}:{ss}</span> : <span className="danger-text">{t("sim.qr.expired")}</span>
        )}
      </div>
    </div>
  );
}

/* ─────────── Backup ─────────── */
function BackupSim({ values }) {
  const { t, tenum } = useI18n();
  const contents = values["backup.contents"] || [];
  const all = ["profile", "settings", "contacts", "messages"];
  const excluded = all.filter((x) => !contents.includes(x));
  const enc = values["backup.encryption"];
  const hasPass = Boolean(values["backup.password"]);
  const size = 12 + contents.length * 37; // фиктивный размер
  const checksum = "sha256:" + (size * 2654435761 % 0xffffff).toString(16).padStart(6, "0");
  return (
    <div className="sim">
      <FlowDiagram kind="backup" values={values} />
      <ul className="kv">
        <li><span>{t("sim.backup.included")}</span><b>{contents.map(tenum).join(", ") || "—"}</b></li>
        <li><span>{t("sim.backup.excluded")}</span><b>{excluded.map(tenum).join(", ") || "—"}</b></li>
        <li><span>{t("sim.backup.size")}</span><b>{size} MB</b></li>
        <li><span>{t("sim.backup.encryption")}</span><b>{enc ? t("sim.backup.on") : t("sim.backup.off")}</b></li>
        <li><span>{t("sim.backup.password")}</span><b>{hasPass ? t("sim.backup.set") : t("sim.backup.notset")}</b></li>
        <li><span>{t("sim.backup.checksum")}</span><b><code>{checksum}</code></b></li>
      </ul>
    </div>
  );
}

/* Небольшой список шагов сценария. */
function Steps({ items }) {
  return (
    <ol className="steps">
      {items.map((s, i) => (
        <li key={i} className={`step ${s.state || "ok"}`}>
          <span className="step-dot" />
          <span className="step-label">
            {s.label}
            {s.value != null && s.value !== "" ? <b> {s.value}</b> : null}
          </span>
        </li>
      ))}
    </ol>
  );
}

function DisabledNote({ text }) {
  return <div className="sim"><div className="notif-note">{text}</div></div>;
}

/* ─────────── Hidden chats ─────────── */
function HiddenChatsSim({ values }) {
  const { t, tset } = useI18n();
  const method = values["hidden.open_method"]; // pin | gesture | secret_command
  const [entry, setEntry] = useState("");
  const [taps, setTaps] = useState(0);
  const [result, setResult] = useState(null);

  if (!values["hidden.enabled"]) return <DisabledNote text={t("sim.hidden.disabled")} />;

  function open() {
    if (method === "pin") setResult(entry && entry === values["hidden.pin"] ? "ok" : "wrong");
    else if (method === "gesture") setResult(taps >= 3 ? "ok" : "wrong");
    else if (method === "secret_command") setResult(entry.trim().length >= 3 ? "ok" : "wrong");
    else setResult("wrong");
  }

  const flags = [
    ["hidden.hide_from_search", values["hidden.hide_from_search"]],
    ["hidden.hide_notifications", values["hidden.hide_notifications"]],
    ["hidden.hide_media", values["hidden.hide_media"]]
  ];

  return (
    <div className="sim">
      <div className="sim-note">{tset("hidden.open_method")}: <b>{method}</b></div>
      {method === "pin" && (
        <div className="pin-row">
          <input className="pin-input" type="password" value={entry} placeholder="••••" onChange={(e) => setEntry(e.target.value)} />
          <button className="btn primary" onClick={open}>{t("sim.hidden.open")}</button>
        </div>
      )}
      {method === "gesture" && (
        <div>
          <p className="muted small">{t("sim.hidden.gesture")} {t("sim.hidden.gestureHint")}</p>
          <div className="gesture-pad">
            {Array.from({ length: 9 }).map((_, i) => (
              <button key={i} className={`dot${i < taps ? " lit" : ""}`} onClick={() => setTaps((v) => v + 1)} />
            ))}
          </div>
          <div className="row-end"><button className="btn primary" onClick={open}>{t("sim.hidden.open")}</button></div>
        </div>
      )}
      {method === "secret_command" && (
        <div className="pin-row">
          <input type="text" value={entry} placeholder="/…" onChange={(e) => setEntry(e.target.value)} />
          <button className="btn primary" onClick={open}>{t("sim.hidden.open")}</button>
        </div>
      )}
      {result === "ok" && (
        <>
          <div className="result ok">{t("sim.hidden.opened")}</div>
          <div>
            <h5 className="sub">{t("sim.hidden.protection")}</h5>
            <ul className="kv">
              {flags.map(([id, on]) => (
                <li key={id}><span>{tset(id)}</span><b>{on ? t("sim.on") : t("sim.off")}</b></li>
              ))}
            </ul>
          </div>
        </>
      )}
      {result === "wrong" && <div className="result bad">{t("sim.hidden.wrong")}</div>}
    </div>
  );
}

/* ─────────── Restore ─────────── */
function RestoreSim({ values }) {
  const { t, tenum } = useI18n();
  const [pass, setPass] = useState("");
  const [result, setResult] = useState(null);

  if (!values["backup.enabled"]) return <DisabledNote text={t("sim.restore.disabled")} />;

  const enc = Boolean(values["backup.encryption"]);
  const realPass = values["backup.password"];
  const contents = values["backup.contents"] || [];

  function run() {
    if (enc && (!realPass || pass !== realPass)) { setResult("badpass"); return; }
    setResult("ok");
  }

  return (
    <div className="sim">
      {enc && (
        <label className="field">
          <span className="field-label">{t("sim.restore.enterPass")}</span>
          <input type="password" value={pass} onChange={(e) => setPass(e.target.value)} placeholder={t("sim.restore.password")} />
        </label>
      )}
      <div className="row-end"><button className="btn primary" onClick={run}>{t("sim.restore.start")}</button></div>
      {result === "badpass" && <div className="result bad">{t("sim.restore.wrongPass")}</div>}
      {result === "ok" && (
        <>
          <Steps items={[
            { label: t("sim.restore.select") },
            { label: t("sim.restore.verify") },
            { label: t("sim.restore.decrypt"), state: enc ? "ok" : "skip" },
            { label: t("sim.restore.write"), value: contents.map(tenum).join(", ") }
          ]} />
          <div className="result ok">{t("sim.restore.done")}</div>
        </>
      )}
    </div>
  );
}

/* ─────────── Trust level ─────────── */
const TRUST_CAPS = {
  unknown:        { message: false, call: false, lastSeen: false, media: false },
  unverified:     { message: true,  call: false, lastSeen: false, media: false },
  contact:        { message: true,  call: true,  lastSeen: false, media: false },
  qr_verified:    { message: true,  call: true,  lastSeen: true,  media: false },
  trusted:        { message: true,  call: true,  lastSeen: true,  media: true },
  corporate_verified: { message: true, call: true, lastSeen: true, media: true }
};
function TrustLevelSim({ values }) {
  const { t, tenum } = useI18n();
  const levels = values["contacts.trust_levels"] || [];
  const [level, setLevel] = useState(levels.find((l) => l !== "blocked") || levels[0]);

  if (!values["contacts.trust_levels_enabled"]) return <DisabledNote text={t("sim.trust.disabled")} />;

  const blocked = level === "blocked";
  const caps = TRUST_CAPS[level] || { message: false, call: false, lastSeen: false, media: false };
  const row = (labelKey, ok) => (
    <li><span>{t(labelKey)}</span><b className={ok ? "cap-ok" : "cap-no"}>{ok ? t("sim.allowed") : t("sim.denied")}</b></li>
  );

  return (
    <div className="sim">
      <p className="muted small">{t("sim.trust.pick")}</p>
      <div className="chips">
        {levels.map((l) => (
          <button key={l} className={level === l ? "chip active" : "chip"} onClick={() => setLevel(l)}>{tenum(l)}</button>
        ))}
      </div>
      <h5 className="sub">{t("sim.trust.caps")}</h5>
      {blocked ? (
        <div className="result bad">{t("sim.trust.blocked")}</div>
      ) : (
        <ul className="kv">
          {row("sim.trust.cap.message", caps.message)}
          {row("sim.trust.cap.call", caps.call)}
          {row("sim.trust.cap.lastSeen", caps.lastSeen)}
          {row("sim.trust.cap.media", caps.media)}
        </ul>
      )}
    </div>
  );
}

/* ─────────── Device pairing ─────────── */
function DevicePairingSim({ values }) {
  const { t, tenum } = useI18n();
  const [ran, setRan] = useState(false);
  const requireApproval = values["devices.require_approval"];
  const methods = values["devices.approval_methods"] || [];
  const historyDefault = values["devices.history_sync_default"];
  const hiddenAccess = values["devices.hidden_access_default"];

  return (
    <div className="sim">
      <div className="row-end"><button className="btn primary" onClick={() => setRan(true)}>{t("sim.pair.run")}</button></div>
      {ran && (
        <>
          <Steps items={[
            { label: t("sim.pair.request") },
            requireApproval
              ? { label: t("sim.pair.approve"), value: methods.map(tenum).join(", ") }
              : { label: t("sim.pair.autoApprove"), state: "warn" },
            { label: t("sim.pair.history"), value: tenum(historyDefault) },
            { label: t("sim.pair.hiddenAccess"), value: hiddenAccess ? t("sim.on") : t("sim.off"), state: hiddenAccess ? "warn" : "ok" }
          ]} />
          <div className="result ok">{t("sim.pair.done")}</div>
        </>
      )}
    </div>
  );
}

/* ─────────── Synchronization ─────────── */
function SynchronizationSim({ values }) {
  const { t, tenum } = useI18n();
  const [net, setNet] = useState("wifi");
  const [ran, setRan] = useState(null);

  if (!values["sync.enabled"]) return <DisabledNote text={t("sim.sync.disabled")} />;

  const types = values["sync.types"] || [];
  const requireWifi = values["sync.network"] === "wifi_only";
  const blocked = requireWifi && net === "mobile";

  return (
    <div className="sim">
      <div className="sim-controls">
        <div className="seg">
          <button className={net === "wifi" ? "on" : ""} onClick={() => { setNet("wifi"); setRan(null); }}>{t("sim.sync.wifi")}</button>
          <button className={net === "mobile" ? "on" : ""} onClick={() => { setNet("mobile"); setRan(null); }}>{t("sim.sync.mobile")}</button>
        </div>
        <button className="btn primary" onClick={() => setRan(true)}>{t("sim.sync.run")}</button>
      </div>
      <div className="sim-note">{t("sim.sync.depth")}: <b>{tenum(values["sync.history_depth"])}</b></div>
      {ran && (blocked ? (
        <div className="result bad">{t("sim.sync.blocked")}</div>
      ) : (
        <>
          <Steps items={types.map((ty) => ({ label: tenum(ty), state: "ok" }))} />
          <div className="result ok">{t("sim.sync.done")}</div>
        </>
      ))}
    </div>
  );
}

/* ─────────── TTL deletion (media) ─────────── */
function TtlDeleteSim({ values }) {
  const { t, tenum } = useI18n();
  if (!values["storage.media_ttl_enabled"]) return <DisabledNote text={t("sim.ttl.disabled")} />;
  return (
    <div className="sim">
      <h5 className="sub">{t("sim.ttl.lifetime")}</h5>
      <div className="timeline">
        <div className="tl-node accent">{t("sim.ttl.created")}</div>
        <div className="tl-bar"><span>{t("sim.ttl.expires")}: {tenum(values["storage.media_ttl"])}</span></div>
        <div className="tl-node danger">{t("sim.ttl.deleted")}</div>
      </div>
    </div>
  );
}

/* ─────────── Auto-delete (messages) ─────────── */
const TTL_DAYS = { "1d": 1, "7d": 7, "30d": 30, "90d": 90, "1y": 365 };
function AutoDeleteSim({ values }) {
  const { t, tenum } = useI18n();
  if (!values["messages.auto_delete_enabled"]) return <DisabledNote text={t("sim.auto.disabled")} />;
  const ttl = values["messages.auto_delete_ttl"];
  const ttlDays = TTL_DAYS[ttl] ?? 7;
  const samples = [1, 5, 10, 40, 100];
  return (
    <div className="sim">
      <div className="sim-note">{t("sim.auto.ttl")}: <b>{tenum(ttl)}</b> ({ttlDays} {t("sim.auto.days")})</div>
      <ul className="kv">
        {samples.map((age) => {
          const kept = age < ttlDays;
          return (
            <li key={age}>
              <span>{t("sim.auto.age")} {age} {t("sim.auto.days")}</span>
              <b className={kept ? "cap-ok" : "cap-no"}>{kept ? t("sim.auto.kept") : t("sim.auto.deleted")}</b>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/* ─────────── Storage usage ─────────── */
function StorageUsageSim({ values }) {
  const { t } = useI18n();
  const limit = Number(values["media.cache_limit_gb"] ?? 2);
  const cache = 2.6; // фиктивное текущее использование кэша, ГБ
  const cleanup = Boolean(values["media.auto_cleanup"]);
  const cats = [
    { key: "sim.usage.cat.messages", gb: 0.4, cls: "b1" },
    { key: "sim.usage.cat.photos", gb: 1.2, cls: "b2" },
    { key: "sim.usage.cat.videos", gb: 2.1, cls: "b3" },
    { key: "sim.usage.cat.cache", gb: cache, cls: "b4", limit }
  ];
  const max = Math.max(limit, ...cats.map((c) => c.gb)) * 1.1;
  const over = cache > limit;
  return (
    <div className="sim">
      <h5 className="sub">{t("sim.usage.title")}</h5>
      <div className="bars">
        {cats.map((c) => (
          <div className="bar-row" key={c.key}>
            <span className="bar-label">{t(c.key)}</span>
            <div className="bar-track">
              <div className={`bar-fill ${c.cls}`} style={{ width: `${(c.gb / max) * 100}%` }} />
              {c.limit != null && <div className="bar-limit" style={{ left: `${(c.limit / max) * 100}%` }} title={`${t("sim.usage.cacheLimit")} ${c.limit} GB`} />}
            </div>
            <span className="bar-val">{c.gb} GB</span>
          </div>
        ))}
      </div>
      <div className="sim-note">{t("sim.usage.cacheLimit")}: <b>{limit} GB</b></div>
      {over && (cleanup
        ? <div className="result warn">{t("sim.usage.over")}</div>
        : <div className="result bad">{t("sim.usage.cleanupOff")}</div>)}
    </div>
  );
}

/* ─────────── Network state ─────────── */
function NetworkStateSim({ values }) {
  const { t, tenum } = useI18n();
  const proxy = values["node.proxy_enabled"];
  const rows = [
    [t("sim.net.node"), tenum(values["node.mode"])],
    [t("sim.net.proxy"), proxy ? `${t("sim.on")} · ${tenum(values["node.proxy_type"])}` : t("sim.off")],
    [t("sim.net.relays"), values["node.allow_relays"] ? t("sim.on") : t("sim.off")],
    [t("sim.net.fallback"), values["node.allow_fallback"] ? t("sim.on") : t("sim.off")],
    [t("sim.net.mobile"), values["node.mobile_data"] ? t("sim.on") : t("sim.off")],
    [t("sim.net.roaming"), values["node.roaming"] ? t("sim.on") : t("sim.off")]
  ];
  const chain = [{ label: "Client", accent: true }];
  if (proxy) chain.push({ label: "Proxy" });
  chain.push({ label: t("sim.net.node") });
  if (values["node.allow_relays"]) chain.push({ label: "Relay" });
  chain.push({ label: "OUO", accent: true });
  return (
    <div className="sim">
      <div className="chain">
        {chain.map((n, i) => (
          <React.Fragment key={i}>
            <div className={`chain-node${n.accent ? " accent" : ""}`}>{n.label}</div>
            {i < chain.length - 1 && <div className="chain-arrow">→</div>}
          </React.Fragment>
        ))}
      </div>
      <ul className="kv">
        {rows.map(([k, v]) => <li key={k}><span>{k}</span><b>{v}</b></li>)}
      </ul>
    </div>
  );
}

/* ─────────── Registry ─────────── */
// key -> { title(ru/en), render, detailed }
export const SIMULATORS = {
  notifications:      { ru: "Уведомления", en: "Notifications", render: (v) => <NotificationSim values={v} />, detailed: true },
  pin:                { ru: "PIN", en: "PIN", render: (v) => <PinSim values={v} />, detailed: true },
  fake_pin:           { ru: "Fake PIN", en: "Fake PIN", render: (v) => <PinSim values={v} />, detailed: true },
  encryption:         { ru: "Шифрование", en: "Encryption", render: (v) => <DiagramSim kind="crypto" values={v} />, detailed: true },
  replication:        { ru: "Репликация", en: "Replication", render: (v) => <ReplicationSim values={v} />, detailed: true },
  message_routing:    { ru: "Маршрут сообщения", en: "Message routing", render: (v) => <DiagramSim kind="route" values={v} />, detailed: true },
  message_delivery:   { ru: "Доставка сообщений", en: "Message delivery", render: (v) => <DiagramSim kind="route" values={v} />, detailed: true },
  qr:                 { ru: "QR", en: "QR", render: (v) => <QrSim values={v} />, detailed: true },
  backup:             { ru: "Backup", en: "Backup", render: (v) => <BackupSim values={v} />, detailed: true },
  hidden_chats:       { ru: "Скрытые чаты", en: "Hidden chats", render: (v) => <HiddenChatsSim values={v} />, detailed: true },
  restore:            { ru: "Восстановление", en: "Restore", render: (v) => <RestoreSim values={v} />, detailed: true },
  media_replication:  { ru: "Репликация медиа", en: "Media replication", render: (v) => <ReplicationSim values={v} />, detailed: true },
  file_storage:       { ru: "Хранение файлов", en: "File storage", render: (v) => <DiagramSim kind="route" values={v} />, detailed: true },
  trust_level:        { ru: "Trust Level", en: "Trust level", render: (v) => <TrustLevelSim values={v} />, detailed: true },
  device_pairing:     { ru: "Device Pairing", en: "Device pairing", render: (v) => <DevicePairingSim values={v} />, detailed: true },
  node_switching:     { ru: "Node Switching", en: "Node switching", render: (v) => <NetworkStateSim values={v} />, detailed: true },
  synchronization:    { ru: "Синхронизация", en: "Synchronization", render: (v) => <SynchronizationSim values={v} />, detailed: true },
  ttl_delete:         { ru: "TTL удаления", en: "TTL deletion", render: (v) => <TtlDeleteSim values={v} />, detailed: true },
  auto_delete:        { ru: "Auto Delete", en: "Auto delete", render: (v) => <AutoDeleteSim values={v} />, detailed: true },
  storage_usage:      { ru: "Storage Usage", en: "Storage usage", render: (v) => <StorageUsageSim values={v} />, detailed: true },
  network_state:      { ru: "Network State", en: "Network state", render: (v) => <NetworkStateSim values={v} />, detailed: true }
};

/** Модальное окно с одним симулятором. */
export function SimulatorModal({ simKey, values, onClose }) {
  const { lang, t } = useI18n();
  const sim = SIMULATORS[simKey];
  if (!sim) return null;
  return (
    <Modal title={`${t("sim.title")}: ${sim[lang]}`} onClose={onClose} wide>
      {sim.render(values)}
    </Modal>
  );
}

/** Хаб со списком всех симуляторов. */
export function SimulatorHub({ values, onClose, onPick }) {
  const { lang, t } = useI18n();
  return (
    <Modal title={t("sim.hub")} onClose={onClose} wide>
      <div className="sim-grid">
        {Object.entries(SIMULATORS).map(([key, s]) => (
          <button key={key} className={`sim-card${s.detailed ? " detailed" : ""}`} onClick={() => onPick(key)}>
            <span>{s[lang]}</span>
            {s.detailed && <em>●</em>}
          </button>
        ))}
      </div>
    </Modal>
  );
}
