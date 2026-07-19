import React, { useRef } from "react";
import { useI18n } from "../../i18n/I18nContext.jsx";
import { EDGE_STYLE, STATUS_COLOR, SEC_STATE_COLOR } from "../../sim/types.js";

const META = {
  user:      { r: 26, glyph: "👤", fill: "#eef4ff", stroke: "#2f6df6" },
  device:    { r: 22, glyph: "📱", fill: "#f4f6fa", stroke: "#6b7280" },
  personal:  { r: 30, glyph: "🖥", fill: "#eafaf1", stroke: "#17915a" },
  public:    { r: 30, glyph: "🌐", fill: "#eef4ff", stroke: "#2f6df6" },
  local:     { r: 30, glyph: "🏠", fill: "#fff7e8", stroke: "#d99a00" },
  home:      { r: 34, glyph: "🏡", fill: "#eafaf1", stroke: "#17915a" },
  bootstrap: { r: 26, glyph: "🧭", fill: "#f4f0ff", stroke: "#7b5bd6" },
  discovery: { r: 26, glyph: "🔎", fill: "#f4f0ff", stroke: "#7b5bd6" },
  relay:     { r: 26, glyph: "🔁", fill: "#f4f0ff", stroke: "#9b59d0" },
  witness:   { r: 26, glyph: "🛡", fill: "#f4f0ff", stroke: "#7b5bd6" },
  storage:   { r: 26, glyph: "🗄", fill: "#eef4ff", stroke: "#2f6df6" },
  friend:    { r: 24, glyph: "🙂", fill: "#eef4ff", stroke: "#2f6df6" },
  scanner:   { r: 24, glyph: "🛰", fill: "#f6eef0", stroke: "#9aa1ad" },
  malicious: { r: 26, glyph: "☠️", fill: "#fdecec", stroke: "#b3261e" },
  update:    { r: 24, glyph: "⬇️", fill: "#eef4ff", stroke: "#2f6df6" },
  qr:        { r: 20, glyph: "▦", fill: "#fff", stroke: "#17191f" },
  identity:  { r: 24, glyph: "🪪", fill: "#f4f0ff", stroke: "#7b5bd6" }
};

const DEVICE_GLYPH = { mobile: "📱", desktop: "🖥", laptop: "💻", web: "🌐", pwa: "🌐" };

function edgeStyle(edge) {
  const st = EDGE_STYLE[edge.kind] || EDGE_STYLE.none;
  return st;
}

const TRANSFER_GLYPH = { text: "✉️", ack: "✅", photo: "🖼", video: "🎞", file: "📄", sync: "🔄", call: "📞", attack: "⚡" };
const TRANSFER_STROKE = { photo: "#9b59d0", video: "#9b59d0", file: "#9b59d0", attack: "#e5484d", call: "#0e9db3" };

export function NetworkCanvas({ state, viewBox, selectedId, onSelect, onDrag, showMetrics, markers, iconScale = 1, selectedMarkerId, onSelectMarker }) {
  const { t, tset } = useI18n();
  const svgRef = useRef(null);
  const dragRef = useRef(null);

  const objects = state.objects;
  const points = Object.values(objects).filter((o) => META[o.kind]);
  const regions = Object.values(objects).filter((o) => o.kind === "lan");

  function toSvg(evt) {
    const svg = svgRef.current;
    const pt = svg.createSVGPoint();
    pt.x = evt.clientX;
    pt.y = evt.clientY;
    const ctm = svg.getScreenCTM();
    if (!ctm) return { x: 0, y: 0 };
    const p = pt.matrixTransform(ctm.inverse());
    return { x: Math.round(p.x), y: Math.round(p.y) };
  }

  function onPointerDown(e, id) {
    e.stopPropagation();
    onSelect(id);
    dragRef.current = { id, moved: false };
    e.currentTarget.setPointerCapture?.(e.pointerId);
  }
  function onPointerMove(e) {
    if (!dragRef.current) return;
    const { x, y } = toSvg(e);
    dragRef.current.moved = true;
    onDrag(dragRef.current.id, x, y);
  }
  function onPointerUp() {
    dragRef.current = null;
  }

  function label(o) {
    if (o.kind === "user") return o.name;
    if (o.kind === "device") return o.id;
    return o.id;
  }

  // message marker position
  let marker = null;
  if (state.message) {
    const edge = state.edges.find((ed) => ed.id === state.message.edgeId);
    if (edge && objects[edge.from] && objects[edge.to]) {
      const a = objects[edge.from], b = objects[edge.to];
      const glyphByKind = { ack: "✅", media: "🖼", message: "✉️" };
      marker = {
        x: (a.x + b.x) / 2,
        y: (a.y + b.y) / 2,
        glyph: glyphByKind[state.message.kind] || "✉️",
        label: state.message.label,
        stroke: state.message.kind === "media" ? "#9b59d0" : "#17915a"
      };
    }
  }

  return (
    <svg ref={svgRef} className="net-canvas" viewBox={viewBox}
      onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerLeave={onPointerUp}
      onClick={() => onSelect(null)}>
      {/* regions (LAN) */}
      {regions.map((r) => (
        <g key={r.id}>
          <rect x={r.x} y={r.y} width={r.w} height={r.h} rx="14"
            fill="#17915a10" stroke="#17915a" strokeDasharray="7 5" strokeWidth="1.5" />
          <text x={r.x + 12} y={r.y + 22} className="net-region-label">{r.label}</text>
        </g>
      ))}

      {/* edges */}
      {state.edges.map((edge) => {
        const a = objects[edge.from];
        const b = objects[edge.to];
        if (!a || !b) return null;
        const st = edgeStyle(edge);
        return (
          <line key={edge.id} x1={a.x} y1={a.y} x2={b.x} y2={b.y}
            stroke={st.color} strokeWidth={st.width} strokeDasharray={st.dash || undefined}
            strokeLinecap="round" opacity="0.95" />
        );
      })}

      {/* message marker */}
      {marker && (
        <g className="net-marker" transform={`translate(${marker.x},${marker.y})`}>
          <circle r="15" fill="#fff" stroke={marker.stroke} strokeWidth="2" />
          <text textAnchor="middle" dy="5" fontSize="15">{marker.glyph}</text>
          {marker.label && <text textAnchor="middle" y="30" className="net-marker-label">{marker.label}</text>}
        </g>
      )}

      {/* live transfer markers (Live Mode) — clickable: show route + latency in inspector */}
      {(markers || []).map((mk) => (
        <g key={mk.id} transform={`translate(${mk.x},${mk.y})`} className="net-tr"
          onPointerDown={(e) => e.stopPropagation()}
          onClick={(e) => { e.stopPropagation(); onSelectMarker && onSelectMarker(mk); }}
          style={{ cursor: onSelectMarker ? "pointer" : "default" }}>
          {selectedMarkerId === mk.id && <circle r="17" fill="none" stroke="#2f6df6" strokeWidth="2" strokeDasharray="3 3" />}
          <circle r="12" fill="#fff" stroke={TRANSFER_STROKE[mk.kind] || "#17915a"} strokeWidth="2" />
          <text textAnchor="middle" dy="4" fontSize="12">{TRANSFER_GLYPH[mk.kind] || "✉️"}</text>
          {mk.label && <text textAnchor="middle" y="24" className="net-marker-label">{mk.label}</text>}
        </g>
      ))}

      {/* point objects */}
      {points.map((o) => {
        const m = META[o.kind];
        const r = Math.max(8, Math.round(m.r * iconScale));
        const ring = SEC_STATE_COLOR[o.secState] || STATUS_COLOR[o.status] || "#9aa1ad";
        const sel = selectedId === o.id;
        const danger = o.secState === "compromised";
        const stroke = danger ? "#b3261e" : m.stroke;
        const cpu = o.metrics?.cpu;
        const ram = o.metrics?.ram;
        const glyph = (o.kind === "device" && DEVICE_GLYPH[o.type]) || m.glyph;
        const showLabel = sel || iconScale >= 0.85;
        return (
          <g key={o.id} transform={`translate(${o.x},${o.y})`} className="net-obj"
            onPointerDown={(e) => onPointerDown(e, o.id)}
            onClick={(e) => { e.stopPropagation(); onSelect(o.id); }}>
            {sel && <circle r={r + 7} fill="none" stroke="#2f6df6" strokeWidth="2" strokeDasharray="3 3" />}
            <circle r={r} fill={danger ? "#fdecec" : m.fill} stroke={stroke} strokeWidth={danger ? 3 : 2} />
            <circle r={Math.max(3, 5 * iconScale)} cx={r - 3} cy={-(r - 3)} fill={ring} stroke="#fff" strokeWidth="1.5" />
            {danger && <text x={-(r - 2)} y={-(r - 6)} fontSize={Math.max(9, 14 * iconScale)}>⚠</text>}
            <text textAnchor="middle" dy="6" fontSize={Math.max(9, (r - 6))}>{glyph}</text>
            {showLabel && <text textAnchor="middle" y={r + 15} className="net-obj-label">{label(o)}</text>}
            {showMetrics && cpu != null && iconScale >= 0.85 && (
              <g transform={`translate(${-22},${r + 22})`}>
                <rect x="0" y="0" width="44" height="5" rx="2.5" fill="#e3e7ee" />
                <rect x="0" y="0" width={Math.max(0, Math.min(44, (cpu / 100) * 44))} height="5" rx="2.5"
                  fill={cpu > 85 ? "#e5484d" : cpu > 60 ? "#d99a00" : "#17915a"} />
                {ram != null && <>
                  <rect x="0" y="7" width="44" height="5" rx="2.5" fill="#e3e7ee" />
                  <rect x="0" y="7" width={Math.max(0, Math.min(44, (ram / 100) * 44))} height="5" rx="2.5" fill="#6b7db8" />
                </>}
              </g>
            )}
          </g>
        );
      })}
    </svg>
  );
}
