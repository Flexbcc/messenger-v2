import React from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";

/**
 * Инспектор (раздел 17 ТЗ): карточка выбранного объекта +
 * панель объяснения «Почему это происходит?» для текущего события.
 */
function nodeLabel(id, objects) {
  const o = objects[id];
  if (!o) return id;
  if (o.kind === "user") return o.name;
  return o.label || o.id;
}

export function InspectorPanel({ state, selectedId, currentEvent, users, selectedMsg }) {
  const { lang, t } = useI18n();
  const obj = !selectedMsg && selectedId ? state.objects[selectedId] : null;

  const kindLabel = (k) => t(`net.kind.${k}`);
  const modeLabel = (m) => (m ? t(`net.mode.${m}`) : "—");
  const stateLabel = (s) => (s ? t(`net.state.${s}`) : "—");

  const rows = [];
  if (obj) {
    rows.push([t("net.f.type"), kindLabel(obj.kind)]);
    rows.push([t("net.f.status"), stateLabel(obj.status)]);
    if (obj.kind === "user") {
      rows.push([t("net.f.publicId"), obj.publicId]);
      rows.push([t("net.f.homeNode"), obj.homeNodeId]);
      rows.push([t("net.f.trust"), obj.trustLevel]);
      const devices = Object.values(state.objects).filter((o) => o.kind === "device" && o.userId === obj.id);
      rows.push([t("net.f.devices"), devices.map((d) => d.id).join(", ") || "—"]);
    } else if (obj.kind === "device") {
      rows.push([t("net.f.owner"), obj.userId]);
      rows.push([t("net.f.deviceType"), obj.type]);
      rows.push([t("net.f.network"), obj.network]);
      rows.push([t("net.f.connectedNode"), obj.connectedNodeId || "—"]);
      if (obj.keyId) rows.push([t("net.f.deviceKey"), obj.revoked ? `${obj.keyId} (${t("net.f.revoked")})` : obj.keyId]);
    } else if (obj.kind === "identity" || obj.kind === "qr") {
      if (obj.ownerUserId) rows.push([t("net.f.owner"), obj.ownerUserId]);
      if (obj.expiresIn != null) rows.push([t("net.f.expires"), `${obj.expiresIn}s`]);
    } else if (["personal", "public", "local", "home"].includes(obj.kind)) {
      if (obj.ownerUserId) rows.push([t("net.f.owner"), obj.ownerUserId]);
      if (obj.networkMode) rows.push([t("net.f.network"), modeLabel(obj.networkMode)]);
      if (obj.publicAddress) rows.push([t("net.f.address"), obj.publicAddress]);
      rows.push([t("net.f.registered"), obj.registered ? t("sim.yes") : t("sim.no")]);
      rows.push([t("net.f.storage"), obj.storageEnabled ? t("sim.on") : t("sim.off")]);
      // users приходит из snap.users (метаданные), т.к. пользователи не хранятся в state.objects.
      const homeUsers = users
        ? users.filter((u) => u.homeNodeId === obj.id)
        : Object.values(state.objects).filter((o) => o.kind === "user" && o.homeNodeId === obj.id);
      const devices = Object.values(state.objects).filter((o) => o.kind === "device" && o.connectedNodeId === obj.id);
      rows.push([t("net.f.users"), String(homeUsers.length)]);
      rows.push([t("net.f.devices"), String(devices.length)]);
    } else {
      rows.push([t("net.f.kind"), kindLabel(obj.kind)]);
    }

    // Секция безопасности/состояния (OUO Home, relay и др.).
    if (obj.secState) rows.push([t("net.f.secState"), t(`net.state.${obj.secState}`) || obj.secState]);
    if (obj.version) rows.push([t("net.f.version"), obj.version]);
    if (obj.supportState) rows.push([t("net.f.support"), t(`net.support.${obj.supportState}`) || obj.supportState]);
    if (obj.knownCriticalVulnerability != null)
      rows.push([t("net.f.vuln"), obj.knownCriticalVulnerability ? t("sim.yes") : t("sim.no")]);
    if (obj.metrics) {
      rows.push([t("net.f.workload"), `${obj.metrics.personal ?? 0}% / ${obj.metrics.community ?? 0}%`]);
      rows.push([t("net.metric.connections"), String(obj.metrics.connections ?? "—")]);
    }
    if (obj.storage) {
      rows.push([t("net.f.secureObjects"), `${obj.storage.secureGb} GB`]);
      rows.push([t("net.f.userLibrary"), `${obj.storage.libraryGb} GB`]);
      rows.push([t("net.f.free"), `${obj.storage.freeGb} GB`]);
    }
  }

  const caps = obj?.capabilities;

  return (
    <aside className="net-inspector">
      <h4>{t("net.inspector")}</h4>
      {selectedMsg ? (
        <div className="ins-msg">
          <div className="ins-title">
            <strong>{selectedMsg.msgLabel?.[lang] ?? selectedMsg.msgLabel?.ru ?? t(`lat.kind.${selectedMsg.kind}`)}</strong>
            <code>{selectedMsg.transferId || selectedMsg.id}</code>
          </div>
          <ul className="kv">
            <li><span>{t("net.f.type")}</span><b>{t(`lat.kind.${selectedMsg.kind}`) || selectedMsg.kind}</b></li>
            <li><span>{t("msg.route")}</span><b><code>{selectedMsg.route}</code></b></li>
            <li><span>{t("msg.latency")}</span><b>~{Math.round(selectedMsg.etaMs)} ms</b></li>
            {selectedMsg.status && <li><span>{t("msg.status")}</span><b>{t(`msg.status.${selectedMsg.status}`)}</b></li>}
            {selectedMsg.progressPct != null && selectedMsg.status !== "delivered" && (
              <li><span>{t("msg.progress")}</span><b>{selectedMsg.progressPct}%</b></li>
            )}
          </ul>
          {selectedMsg.path && (
            <div className="ins-path">
              <h5>{t("msg.path")}</h5>
              <div className="ins-path-hops">
                {selectedMsg.path.map((id, i) => (
                  <React.Fragment key={id}>
                    {i > 0 && <span className="ins-path-arrow">→</span>}
                    <span className="ins-path-hop">{nodeLabel(id, state.objects)}</span>
                  </React.Fragment>
                ))}
              </div>
            </div>
          )}
          {selectedMsg.why && (
            <div className="net-why">
              <h5>{t("net.why")}</h5>
              <p>{selectedMsg.why[lang] ?? selectedMsg.why.ru}</p>
            </div>
          )}
        </div>
      ) : obj ? (
        <>
          <div className="ins-title">
            <strong>{obj.name || obj.label || obj.id}</strong>
            <code>{obj.id}</code>
          </div>
          <ul className="kv">
            {rows.map(([k, v]) => <li key={k}><span>{k}</span><b>{v}</b></li>)}
          </ul>
          {caps && (
            <div className="ins-caps">
              <h5>{t("net.f.capabilities")}</h5>
              <div className="cap-chips">
                {["messaging", "personal_storage", "sync", "relay", "temporary_storage", "discovery", "witness", "update"].map((c) => {
                  const on = caps.includes(c);
                  return <span key={c} className={`cap ${on ? "on" : "off"}`}>{on ? "✓" : "✕"} {t(`net.cap.${c}`)}</span>;
                })}
              </div>
            </div>
          )}
        </>
      ) : (
        <p className="muted small">{t("net.clickHint")}</p>
      )}

      {currentEvent?.why && (
        <div className="net-why">
          <h5>{t("net.why")}</h5>
          <p>{currentEvent.why[lang] ?? currentEvent.why.ru}</p>
        </div>
      )}

      <div className="net-legend">
        <h5>{t("net.legend")}</h5>
        <ul>
          <li><i className="leg service" />{t("net.leg.service")}</li>
          <li><i className="leg direct" />{t("net.leg.direct")}</li>
          <li><i className="leg relay" />{t("net.leg.relay")}</li>
          <li><i className="leg delivered" />{t("net.leg.delivered")}</li>
          <li><i className="leg potential" />{t("net.leg.potential")}</li>
          <li><i className="leg media" />{t("net.leg.media")}</li>
        </ul>
      </div>
    </aside>
  );
}
