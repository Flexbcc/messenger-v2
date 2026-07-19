import React from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { buildLatencyTable, ROUTE_IDS } from "../../sim/latency.js";

function fmt(ms) { return `${Math.round(ms)}`; }

function heatColor(ms, max) {
  const t = Math.min(1, ms / max);
  // зелёный → жёлтый → красный
  const hue = 130 - t * 130;
  return `hsl(${hue}, 70%, 90%)`;
}

/**
 * Справочная таблица теоретической задержки доставки (мс) по типу сообщения
 * и маршруту — не измерение реальной сети, а порядок величины (см. latency.js).
 * Если переданы live-статы (stats.latencyByRoute/ByKind), под таблицей
 * показывается фактическое среднее по текущей симуляции.
 */
export function LatencyPanel({ stats }) {
  const { t } = useI18n();
  const table = buildLatencyTable();
  const maxTyp = Math.max(...table.flatMap((row) => ROUTE_IDS.map((r) => row.cells[r].typ)));

  return (
    <div className="lat-panel">
      <p className="muted small">{t("lat.hint")}</p>
      <div className="lat-table-wrap">
        <table className="lat-table">
          <thead>
            <tr>
              <th>{t("lat.kindCol")}</th>
              {ROUTE_IDS.map((r) => <th key={r}><code>{r}</code></th>)}
            </tr>
          </thead>
          <tbody>
            {table.map((row) => (
              <tr key={row.kind}>
                <td className="lat-kind">{t(`lat.kind.${row.kind}`)}</td>
                {ROUTE_IDS.map((r) => {
                  const c = row.cells[r];
                  return (
                    <td key={r} style={{ background: heatColor(c.typ, maxTyp) }} title={`${t("lat.range")}: ${fmt(c.min)}–${fmt(c.max)} ms`}>
                      <b>{fmt(c.typ)}</b> <span className="lat-unit">ms</span>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="lat-foot muted small">{t("lat.note")}</p>

      {stats?.latencyByRoute && Object.keys(stats.latencyByRoute).length > 0 && (
        <div className="lat-live">
          <h5>{t("lat.liveAvg")}</h5>
          <ul className="lat-live-list">
            {Object.entries(stats.latencyByRoute)
              .filter(([, v]) => v.count > 0)
              .sort((a, b) => b[1].count - a[1].count)
              .map(([route, v]) => (
                <li key={route}>
                  <code>{route}</code>
                  <span>{fmt(v.sumMs / v.count)} ms</span>
                  <small className="muted">× {v.count}</small>
                </li>
              ))}
          </ul>
        </div>
      )}
    </div>
  );
}
