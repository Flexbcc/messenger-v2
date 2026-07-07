(function () {
  const urlInput = document.getElementById("discoveryUrl");
  const refreshBtn = document.getElementById("refreshBtn");
  const tbody = document.getElementById("nodesBody");

  const STORAGE_KEY = "node_monitor_discovery_url";
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved) urlInput.value = saved;

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  const PING_TIMEOUT_MS = 4000;
  const REFRESH_INTERVAL_MS = 5000;
  const HISTORY_MAX_SAMPLES = 40; // ~3.3 min of history at a 5s poll interval

  // In-memory only — resets on page reload. Good enough for "watch it live"
  // without adding a persistence layer to what's still a read-only bootstrap
  // monitoring tool (ADR-0006).
  const history = new Map(); // node_id -> { ping: (number|null)[], load: (number|null)[] }

  function recordHistory(nodeId, pingMs, loadValue) {
    if (!history.has(nodeId)) history.set(nodeId, { ping: [], load: [] });
    const h = history.get(nodeId);
    h.ping.push(pingMs);
    h.load.push(loadValue);
    if (h.ping.length > HISTORY_MAX_SAMPLES) h.ping.shift();
    if (h.load.length > HISTORY_MAX_SAMPLES) h.load.shift();
  }

  function formatBytes(bytes) {
    if (!bytes) return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    let i = 0;
    let v = bytes;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  }

  function formatLoad(role, load) {
    if (!load) return "—";
    switch (role) {
      case "home":
        return `${load.online_users} онлайн · ${load.active_ws_connections} WS`;
      case "relay":
        return `${load.forwarded_count} переслано`;
      case "storage":
        return `${load.buffered_count} в буфере`;
      case "media":
        return `${load.files_count} файлов · ${formatBytes(load.bytes_total)}`;
      case "discovery":
        return `${load.registered_nodes} нод · ${load.registered_users} польз.`;
      case "gateway":
        return `${load.proxied_requests ?? 0} прокси`;
      default:
        return "—";
    }
  }

  // A single representative number per role, so it can be plotted as a trend
  // even though each role's `load` shape is different.
  function primaryLoadValue(role, load) {
    if (!load) return null;
    switch (role) {
      case "home": return load.active_ws_connections;
      case "relay": return load.forwarded_count;
      case "storage": return load.buffered_count;
      case "media": return load.files_count;
      case "discovery": return load.registered_nodes;
      case "gateway": return load.proxied_requests;
      default: return null;
    }
  }

  function pingClass(ms) {
    if (ms == null) return "ping-dead";
    if (ms < 100) return "ping-good";
    if (ms < 300) return "ping-ok";
    return "ping-bad";
  }

  // Renders a minimal inline trend line. Gaps (null = unreachable/no data)
  // break the line rather than interpolating through them, so a node going
  // offline is visible as a hole, not a smoothed-over dip.
  function sparkline(values, { width = 72, height = 20 } = {}) {
    const known = values.filter((v) => v != null);
    if (known.length < 2) return '<span class="spark-empty">—</span>';

    const min = Math.min(...known);
    const max = Math.max(...known);
    const range = max - min || 1;
    const stepX = width / (values.length - 1 || 1);

    const segments = [];
    let current = [];
    values.forEach((v, i) => {
      if (v == null) {
        if (current.length > 1) segments.push(current);
        current = [];
        return;
      }
      const x = i * stepX;
      const y = height - ((v - min) / range) * (height - 3) - 1.5;
      current.push(`${x.toFixed(1)},${y.toFixed(1)}`);
    });
    if (current.length > 1) segments.push(current);

    const polylines = segments
      .map((pts) => `<polyline points="${pts.join(" ")}" />`)
      .join("");
    return `<svg class="spark" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none">${polylines}</svg>`;
  }

  async function pingNode(node) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), PING_TIMEOUT_MS);
    const t0 = performance.now();
    try {
      const res = await fetch(`${node.node_url.replace(/\/$/, "")}/health`, {
        cache: "no-store",
        signal: controller.signal,
      });
      const ms = performance.now() - t0;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      return { ms, reachable: true, load: data.load || null, role: data.node_role || null };
    } catch (err) {
      return { ms: null, reachable: false, load: null, role: null };
    } finally {
      clearTimeout(timer);
    }
  }

  async function refresh() {
    try {
      const res = await fetch("/api/monitor/registry/nodes");
      if (!res.ok) {
        const errText = await res.text();
        throw new Error(errText || `HTTP ${res.status}`);
      }
      const data = await res.json();
      const nodes = data.nodes || [];
      const pings = await Promise.all(nodes.map(pingNode));
      renderNodes(nodes.map((n, i) => ({ ...n, ping: pings[i] })));
    } catch (err) {
      const base = urlInput.value.trim() || "discovery";
      tbody.innerHTML = `<tr><td colspan="12" class="empty">Не удалось получить данные (${escapeHtml(base)}): ${escapeHtml(err.message)}</td></tr>`;
    }
  }

  async function initDiscoveryLabel() {
    try {
      const cfg = await fetch("/api/config").then((r) => r.json());
      const url = cfg.discovery_public_url || cfg.node?.discovery_node_url;
      if (url) urlInput.value = url;
    } catch (_) {
      /* ignore */
    }
  }

  function renderNodes(nodes) {
    if (!nodes.length) {
      tbody.innerHTML = '<tr><td colspan="12" class="empty">Пока нет зарегистрированных узлов</td></tr>';
      return;
    }
    nodes.sort((a, b) => a.node_id.localeCompare(b.node_id));
    tbody.innerHTML = nodes.map((n) => {
      const role = (n.capabilities || [])[0];
      const ping = n.ping || { ms: null, reachable: false, load: null };
      const pingLabel = ping.reachable ? `${ping.ms.toFixed(0)} мс` : "недоступен";
      const loadValue = primaryLoadValue(role, ping.load);

      recordHistory(n.node_id, ping.ms, loadValue);
      const h = history.get(n.node_id);

      const trust = n.trust_status || "trusted";
      const reach = n.reachability || n.status || "offline";

      return `
      <tr>
        <td><span class="status-dot status-${reach}"></span>${escapeHtml(reach)}</td>
        <td><code>${escapeHtml(n.node_id)}</code></td>
        <td>${(n.capabilities || []).map(escapeHtml).join(", ")}</td>
        <td><code>${escapeHtml(n.node_url)}</code></td>
        <td>${escapeHtml(n.software_version)}</td>
        <td class="metric-cell">
          <div class="metric-line"><span class="ping-dot ${pingClass(ping.ms)}"></span>${escapeHtml(pingLabel)}</div>
          ${sparkline(h.ping)}
        </td>
        <td class="metric-cell">
          <div class="metric-line">${escapeHtml(formatLoad(role, ping.load))}</div>
          ${sparkline(h.load)}
        </td>
        <td><code class="trust-${trust}">${escapeHtml(trust)}</code></td>
        <td><code>${escapeHtml(n.build_hash || "—")}</code></td>
        <td><code class="trust-${n.attestation_status || "skipped"}">${escapeHtml(n.attestation_status || "skipped")}</code></td>
        <td><code>${escapeHtml(n.cluster_id || "default")}</code></td>
        <td>${escapeHtml(new Date(n.last_heartbeat).toLocaleString())}</td>
      </tr>
    `;
    }).join("");
  }

  refreshBtn.addEventListener("click", refresh);
  initDiscoveryLabel().then(refresh);
  setInterval(refresh, REFRESH_INTERVAL_MS);
})();
