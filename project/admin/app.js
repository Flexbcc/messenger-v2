(function () {
  const refreshBtn = document.getElementById("refreshBtn");
  const connectionsBody = document.getElementById("connectionsBody");
  const connCount = document.getElementById("connCount");

  const REFRESH_MS = 5000;

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function formatBytes(bytes) {
    if (!bytes) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let v = bytes;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  }

  function formatUptime(sec) {
    if (sec == null) return "—";
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 48) return `${Math.floor(h / 24)} д`;
    if (h > 0) return `${h} ч ${m} м`;
    return `${m} м`;
  }

  const STATUS_RU = {
    normal: "Норма",
    busy: "Нагрузка",
    overloaded: "Перегруз",
    critical: "Критично",
    online: "Онлайн",
    offline: "Оффлайн",
  };

  const STATUS_CLASS = {
    normal: "status-normal",
    busy: "status-busy",
    overloaded: "status-overloaded",
    critical: "status-critical",
    online: "status-online",
    offline: "status-offline",
  };

  function setHealthRing(score) {
    const arc = document.getElementById("healthArc");
    const label = document.getElementById("healthScore");
    if (score == null) {
      label.textContent = "—";
      arc.style.strokeDashoffset = "327";
      return;
    }
    label.textContent = String(score);
    const circumference = 2 * Math.PI * 52;
    const offset = circumference * (1 - score / 100);
    arc.style.strokeDasharray = `${circumference}`;
    arc.style.strokeDashoffset = String(offset);
    arc.classList.toggle("health-low", score < 60);
    arc.classList.toggle("health-mid", score >= 60 && score < 85);
    arc.classList.toggle("health-high", score >= 85);
  }

  function renderLocalSnapshot(snap) {
    if (!snap) return;
    document.getElementById("metricsGrid").classList.remove("hidden");
    document.getElementById("connectionsPanel").classList.remove("hidden");
    document.getElementById("monitorDetailsRow").classList.remove("monitor-limited");
    const status = snap.runtime_status || "normal";
    const pill = document.getElementById("runtimeStatusPill");
    pill.textContent = snap.runtime_status_label || STATUS_RU[status] || status;
    pill.className = `status-pill ${STATUS_CLASS[status] || ""}`;

    document.getElementById("localNodeTitle").textContent = snap.node_id || "Home Node";
    const net = snap.network || {};
    const metaBits = [
      net.software_version ? `v${net.software_version}` : null,
      net.resource_policy || null,
      typeof window.__opsCluster === "string" ? window.__opsCluster : null,
    ].filter(Boolean);
    document.getElementById("localNodeMeta").textContent = metaBits.join(" · ") || "Загрузка…";
    renderParticipationOverview(net);

    setHealthRing(snap.health_score);
    AdminAlerts.renderBanner(document.getElementById("alertsBanner"), AdminAlerts.check(snap.metrics));
    const m = snap.metrics || {};
    document.getElementById("mCpu").textContent =
      m.cpu_percent_est != null ? `${m.cpu_percent_est}%` : "—";
    document.getElementById("mRam").textContent =
      m.ram_total_bytes
        ? `${formatBytes(m.ram_used_bytes)} / ${formatBytes(m.ram_total_bytes)}${m.ram_percent != null ? ` (${m.ram_percent}%)` : ""}`
        : "—";
    document.getElementById("mDisk").textContent =
      m.disk_total_bytes
        ? `${formatBytes(m.disk_used_bytes)} / ${formatBytes(m.disk_total_bytes)}${m.disk_percent != null ? ` (${m.disk_percent}%)` : ""}`
        : "—";
    document.getElementById("mConn").textContent =
      `${m.online_users ?? 0} польз. · ${m.active_ws_connections ?? 0} WS`;
    document.getElementById("mSync").textContent = String(m.sync_queue ?? 0);
    document.getElementById("mUptime").textContent = formatUptime(m.uptime_sec);

    const conns = snap.connections || [];
    connCount.textContent = String(conns.length);
    if (!conns.length) {
      connectionsBody.innerHTML =
        '<tr><td colspan="4" class="empty">Нет активных сессий</td></tr>';
    } else {
      connectionsBody.innerHTML = conns.map((c) => `
        <tr>
          <td><code>${escapeHtml(c.user_id)}</code></td>
          <td><code>${escapeHtml(c.device_id || "—")}</code></td>
          <td>${escapeHtml(c.device_type || "—")}</td>
          <td>${escapeHtml(String(c.ws_connections ?? 1))}</td>
        </tr>
      `).join("");
    }
  }

  function renderSnapshotUnavailable() {
    const pill = document.getElementById("runtimeStatusPill");
    pill.textContent = "Базовые сервисы работают";
    pill.className = "status-pill status-online";
    document.getElementById("localNodeTitle").textContent = "Локальная нода";
    document.getElementById("localNodeMeta").textContent =
      "Базовое состояние доступно · приватные метрики Home Node не подключены";
    document.getElementById("healthScore").textContent = "—";
    const banner = document.getElementById("alertsBanner");
    banner.classList.remove("hidden", "warn-banner");
    banner.innerHTML =
      '<strong>Подробный мониторинг недоступен</strong> ' +
      'Admin и Home Node запущены без общего OWNER_PANEL_SECRET. Поэтому CPU, RAM, подключения и аптайм намеренно не выдаются; реестр и состояние сервисов доступны.';
    document.getElementById("metricsGrid").classList.add("hidden");
    document.getElementById("connectionsPanel").classList.add("hidden");
    document.getElementById("monitorDetailsRow").classList.add("monitor-limited");
  }

  const PART_LABELS = {
    relay: "Relay",
    storage: "Storage",
    witness: "Witness",
    media_cache: "Media Cache",
    nat_assist: "NAT Assist",
  };

  function renderParticipationOverview(net) {
    const owner = net.owner_resource_percent ?? 40;
    const network = net.network_resource_percent ?? (100 - owner);
    const ownerBar = document.getElementById("priorityOwnerBar");
    const netBar = document.getElementById("priorityNetworkBar");
    if (ownerBar) ownerBar.style.width = `${owner}%`;
    if (netBar) netBar.style.width = `${network}%`;

    const summary = document.getElementById("participationSummary");
    if (summary) {
      summary.textContent = `Приоритет владельца ${owner}% · сеть ${network}%`;
    }

    const part = net.participation || {};
    const tags = document.getElementById("participationTags");
    if (!tags) return;
    const enabled = Object.entries(PART_LABELS)
      .filter(([key]) => part[key])
      .map(([, label]) => `<li class="tag-on">${escapeHtml(label)}</li>`);
    const disabled = Object.entries(PART_LABELS)
      .filter(([key]) => !part[key])
      .map(([, label]) => `<li class="tag-off">${escapeHtml(label)}</li>`);
    tags.innerHTML = [...enabled, ...disabled].join("") || "<li class='tag-off'>—</li>";
  }

  function updateNodeSummary(nodes) {
    const online = nodes.filter((node) =>
      (node.reachability || node.status || "offline") === "online").length;
    const attention = nodes.filter((node) => {
      const reachable = (node.reachability || node.status || "offline") === "online";
      const trust = node.trust_status || "unknown";
      return !reachable || !["trusted", "local"].includes(trust);
    }).length;
    const el = (id) => document.getElementById(id);
    if (el("sumTotal")) el("sumTotal").textContent = String(nodes.length);
    if (el("sumOnline")) el("sumOnline").textContent = String(online);
    if (el("sumOffline")) el("sumOffline").textContent = String(attention);
  }

  async function refresh() {
    let localSnap = null;
    let nodes = [];

    try {
      const localRes = await fetch(AdminBase.url("/api/monitor/local/snapshot"));
      if (localRes.ok) {
        localSnap = await localRes.json();
        renderLocalSnapshot(localSnap);
      } else {
        renderSnapshotUnavailable();
      }
    } catch (_) {
      renderSnapshotUnavailable();
    }

    try {
      const res = await fetch(AdminBase.url("/api/monitor/registry/nodes/all"));
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      nodes = data.nodes || [];
      updateNodeSummary(nodes);
    } catch (_) { /* сводка сети останется недоступной */ }
  }

  async function initDiscoveryLabel() {
    try {
      const cfg = await fetch(AdminBase.url("/api/config")).then((r) => r.json());
      const cluster = cfg.node?.cluster_id || "default";
      window.__opsCluster = cluster;
      const homeUrl = cfg.node?.home_node_public_url || "";
      const stackLabel = document.getElementById("localStackLabel");
      const meta = cfg.meta || {};
      if (stackLabel) {
        const prefix = meta.title || "Project-стек";
        stackLabel.textContent = `${prefix} · cluster ${cluster} · ${homeUrl || "home"}`;
      }
      document.querySelector(".brand h1")?.replaceChildren(document.createTextNode(
        meta.admin_variant === "main" ? "Operator Console" : "Operator Admin",
      ));
      const n = cfg.node || {};
      renderParticipationOverview({
        owner_resource_percent: n.owner_resource_percent ?? 40,
        network_resource_percent: 100 - (n.owner_resource_percent ?? 40),
        participation: {
          relay: n.participate_relay,
          storage: n.participate_storage,
          witness: n.participate_witness,
          media_cache: n.participate_media_cache,
          nat_assist: n.participate_nat_assist,
        },
      });
    } catch (_) { /* ignore */ }
  }

  AdminToolbar.init(refresh, { autoRefresh: true });
  initDiscoveryLabel().then(refresh);
  AdminServices.refreshContainer(document.getElementById("servicesStatusRow"), {
    statusRow: true,
    only: ["home-node", "storage-node", "media-node", "relay-node"],
  });
  setInterval(refresh, REFRESH_MS);
})();
