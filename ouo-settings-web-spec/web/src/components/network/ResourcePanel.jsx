import React from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { SEC_STATE_COLOR } from "../../sim/types.js";

function Meter({ label, value, unit = "%", warnAt = 70, critAt = 90 }) {
  const pct = Math.max(0, Math.min(100, value ?? 0));
  const color = pct >= critAt ? "#e5484d" : pct >= warnAt ? "#d99a00" : "#17915a";
  return (
    <div className="res-row">
      <span className="res-label">{label}</span>
      <div className="res-track"><div className="res-fill" style={{ width: `${pct}%`, background: color }} /></div>
      <span className="res-val">{Math.round(value ?? 0)}{unit}</span>
    </div>
  );
}

/**
 * Панель ресурсов и состояния OUO Home (разделы 9–11, 29 ТЗ).
 * Читает focus-узел на текущем шаге симуляции.
 */
export function ResourcePanel({ node }) {
  const { t } = useI18n();
  if (!node) return null;
  const m = node.metrics || {};
  const stateColor = SEC_STATE_COLOR[node.secState] || "#9aa1ad";
  const personal = m.personal ?? 0;
  const community = m.community ?? 0;
  const reserve = Math.max(0, 100 - personal - community);

  return (
    <div className="res-panel">
      <div className="res-badge" style={{ background: stateColor }}>
        {t(`net.state.${node.secState}`) || node.secState}
      </div>

      <div className="res-split" title={t("net.res.split")}>
        <div className="seg-p" style={{ flex: personal }} />
        <div className="seg-c" style={{ flex: community }} />
        <div className="seg-r" style={{ flex: reserve }} />
      </div>
      <div className="res-split-legend">
        <span><i className="dot p" />{t("net.res.personal")} {personal}%</span>
        <span><i className="dot c" />{t("net.res.community")} {community}%</span>
        <span><i className="dot r" />{t("net.res.reserve")} {reserve}%</span>
      </div>

      <Meter label={t("net.metric.cpu")} value={m.cpu} />
      <Meter label={t("net.metric.ram")} value={m.ram} />
      <Meter label={t("net.metric.disk")} value={m.disk} />

      <ul className="res-nums">
        <li><span>{t("net.metric.connections")}</span><b>{m.connections ?? "—"}</b></li>
        <li><span>{t("net.metric.transfers")}</span><b>{m.transfers ?? "—"}</b></li>
        <li><span>{t("net.metric.egress")}</span><b>{m.egress ?? "—"} Mbps</b></li>
      </ul>
    </div>
  );
}
