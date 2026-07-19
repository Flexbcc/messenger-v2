(function () {
  const metricsBody = document.getElementById("metricsBody");
  const clusterFilter = document.getElementById("clusterFilter");
  const roleFilter = document.getElementById("roleFilter");
  const adminSecret = document.getElementById("adminSecret");
  const status = document.getElementById("status");
  const alertsBanner = document.getElementById("alertsBanner");
  const REFRESH_MS = 8000;

  let allRows = [];
  let discoveryUrl = "";

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function formatBytes(bytes) {
    if (bytes == null) return "—";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let v = bytes;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  }

  function fmtCpu(m) {
    if (!m || m.cpu_percent_est == null) return "—";
    return `${m.cpu_percent_est}%`;
  }

  function fmtRam(m) {
    if (!m || m.ram_total_bytes == null) return "—";
    const pct = m.ram_percent != null ? ` (${m.ram_percent}%)` : "";
    return `${formatBytes(m.ram_used_bytes)} / ${formatBytes(m.ram_total_bytes)}${pct}`;
  }

  function fmtDisk(m) {
    if (!m || m.disk_total_bytes == null) return "—";
    const pct = m.disk_percent != null ? ` (${m.disk_percent}%)` : "";
    return `${formatBytes(m.disk_used_bytes)} / ${formatBytes(m.disk_total_bytes)}${pct}`;
  }

  function clusterLabel(id) {
    return AdminClusters.KNOWN_SITES[id]?.title || id || "default";
  }

  function populateFilters(rows) {
    const clusters = [...new Set(rows.map((r) => r.cluster_id || "default"))].sort();
    const cur = clusterFilter.value;
    clusterFilter.innerHTML = '<option value="">Все</option>' +
      clusters.map((c) => `<option value="${escapeHtml(c)}">${escapeHtml(clusterLabel(c))}</option>`).join("");
    clusterFilter.value = cur;
  }

  function filteredRows() {
    return allRows.filter((r) => {
      const c = r.cluster_id || "default";
      if (clusterFilter.value && c !== clusterFilter.value) return false;
      if (roleFilter.value && r.role !== roleFilter.value) return false;
      return true;
    });
  }

  function rowClass(m) {
    const alerts = AdminAlerts.check(m);
    return alerts.length ? "row-alert" : "";
  }

  function renderTable() {
    const rows = filteredRows();
    const allAlerts = [];
    if (!rows.length) {
      metricsBody.innerHTML = '<tr><td colspan="11" class="empty">Нет нод по фильтру</td></tr>';
      AdminAlerts.renderBanner(alertsBanner, []);
      return;
    }
    metricsBody.innerHTML = rows.map((r) => {
      const trust = r.trust_status || "trusted";
      const online = r.reachable ? "online" : "offline";
      const m = r.metrics;
      allAlerts.push(...AdminAlerts.check(m));
      const ws = m?.active_ws_connections ?? r.load?.active_ws_connections ?? "—";
      const ping = r.latency_ms != null ? `${Math.round(r.latency_ms)} ms` : "—";
      const actions = trustActions(r.node_id, trust);
      return `<tr class="${rowClass(m)}">
        <td><strong>${escapeHtml(clusterLabel(r.cluster_id || "default"))}</strong><div class="muted-xs">${escapeHtml(r.cluster_id || "default")}</div></td>
        <td><code>${escapeHtml(r.node_id)}</code></td>
        <td>${AdminUi.rolePill(r.role)}</td>
        <td>${AdminUi.trustPill(trust)}</td>
        <td>${AdminUi.statusPill(online, online === "online" ? "OK" : "off")}</td>
        <td>${escapeHtml(fmtCpu(m))}</td>
        <td>${escapeHtml(fmtRam(m))}</td>
        <td>${escapeHtml(fmtDisk(m))}</td>
        <td>${escapeHtml(String(ws))}</td>
        <td>${escapeHtml(ping)}</td>
        <td class="actions-cell">${actions}</td>
      </tr>`;
    }).join("");
    AdminAlerts.renderBanner(alertsBanner, allAlerts);

    metricsBody.querySelectorAll("[data-trust-action]").forEach((btn) => {
      btn.addEventListener("click", () => runTrustAction(btn.dataset.trustAction, btn.dataset.nodeId));
    });
  }

  function trustActions(nodeId, trust) {
    const parts = [];
    if (trust === "pending") {
      parts.push(`<button type="button" class="btn-xs btn-primary" data-trust-action="approve" data-node-id="${escapeHtml(nodeId)}">Принять</button>`);
    }
    if (trust === "trusted") {
      parts.push(`<button type="button" class="btn-xs btn-secondary" data-trust-action="suspend" data-node-id="${escapeHtml(nodeId)}">Suspend</button>`);
      parts.push(`<button type="button" class="btn-xs btn-danger" data-trust-action="compromise" data-node-id="${escapeHtml(nodeId)}">Отозвать</button>`);
    }
    if (trust === "suspended") {
      parts.push(`<button type="button" class="btn-xs btn-primary" data-trust-action="reinstate" data-node-id="${escapeHtml(nodeId)}">Вернуть</button>`);
      parts.push(`<button type="button" class="btn-xs btn-danger" data-trust-action="compromise" data-node-id="${escapeHtml(nodeId)}">Отозвать</button>`);
    }
    return parts.join(" ") || "—";
  }

  async function runTrustAction(action, nodeId) {
    const secret = adminSecret?.value?.trim();
    if (!secret) {
      AdminApi.showStatus(status, "Введите DISCOVERY_ADMIN_SECRET", false);
      return;
    }
    if (action === "suspend" && !confirm(`Приостановить ${nodeId}?`)) return;
    if (action === "compromise" && !confirm(`Отозвать доступ ${nodeId}?`)) return;
    const path = `/admin/registry/nodes/${encodeURIComponent(nodeId)}/${action}`;
    const body = action === "suspend" ? { reason: "operator suspend" } : undefined;
    try {
      const res = await AdminTrust.request(discoveryUrl, path, { secret, body });
      AdminApi.showStatus(status, res.message || `${action}: OK`, true);
      await refresh();
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  }

  async function refresh() {
    try {
      const res = await fetch(AdminBase.url("/api/monitor/registry/metrics"));
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      allRows = data.nodes || [];
      populateFilters(allRows);
      renderTable();
    } catch (e) {
      metricsBody.innerHTML = `<tr><td colspan="11" class="empty">${escapeHtml(e.message)}</td></tr>`;
    }
  }

  async function init() {
    try {
      const cfg = await AdminApi.getConfig();
      discoveryUrl = cfg.node?.discovery_node_url || "";
      if (cfg.meta?.admin_variant === "main") {
        document.querySelectorAll('.site-nav a[href="storage"]').forEach((a) => a.remove());
        const sub = document.getElementById("opsSubtitle");
        if (sub) sub.textContent = `Главная нода · ${cfg.node?.cluster_id || "operator-main"}`;
      }
    } catch (_) { /* ignore */ }
    const saved = sessionStorage.getItem(AdminTrust.SECRET_KEY);
    if (saved && adminSecret) adminSecret.value = saved;
    clusterFilter.addEventListener("change", renderTable);
    roleFilter.addEventListener("change", renderTable);
    document.getElementById("refreshBtn")?.addEventListener("click", refresh);
    await refresh();
    setInterval(refresh, REFRESH_MS);
  }

  init();
})();
