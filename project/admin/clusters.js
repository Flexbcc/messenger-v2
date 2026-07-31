/** Group Discovery registry rows into deployment sites (clusters). */
const AdminClusters = {
  WORKER_ROLES: ["home", "media", "relay", "storage"],
  ROLE_META: {
    home: { label: "Home", icon: "🏠" },
    media: { label: "Media", icon: "🎬" },
    relay: { label: "Relay", icon: "🔀" },
    storage: { label: "Storage", icon: "📦" },
  },

  KNOWN_SITES: {
    default: { title: "Project (dev-стек)", hint: "Operator Admin :9201 · Home :8001", kind: "project" },
    "operator-main": { title: "Главная нода", hint: "Панель :9205/panel", kind: "main" },
    "client-test": { title: "Client-node (тест)", hint: "Панель :18011/panel", kind: "client" },
  },

  roleOf(node) {
    return String((node.capabilities || [])[0] || "node").toLowerCase();
  },

  /** Prefer one live row per cluster+role (ignore stale test duplicates). */
  nodeScore(node) {
    let score = 0;
    const status = String(node.status || node.reachability || "offline").toLowerCase();
    if (status === "online") score += 100;
    if ((node.ping || {}).reachable) score += 50;
    const id = String(node.node_id || "");
    if (id.endsWith("-local") || id.includes("-operator-") || id.includes("-client-")) score += 15;
    if (id.includes("dockertest") || id.startsWith("test-") || id.includes("-e2e")) score -= 40;
    if (node.last_heartbeat) {
      const age = Date.now() - Date.parse(node.last_heartbeat);
      if (!Number.isNaN(age) && age < 3600_000) score += 10;
    }
    return score;
  },

  dedupeNodes(nodes) {
    const best = new Map();
    for (const n of nodes || []) {
      const role = this.roleOf(n);
      if (!this.WORKER_ROLES.includes(role)) continue;
      const cluster = n.cluster_id || "default";
      const key = `${cluster}:${role}`;
      const prev = best.get(key);
      if (!prev || this.nodeScore(n) > this.nodeScore(prev)) best.set(key, n);
    }
    return Array.from(best.values());
  },

  groupNodes(nodes) {
    const map = new Map();
    for (const n of this.dedupeNodes(nodes)) {
      const role = this.roleOf(n);
      if (!this.WORKER_ROLES.includes(role)) continue;
      const cluster = n.cluster_id || "default";
      if (!map.has(cluster)) {
        map.set(cluster, { cluster_id: cluster, roles: {}, nodes: [] });
      }
      const g = map.get(cluster);
      g.roles[role] = n;
      g.nodes.push(n);
    }
    return Array.from(map.values()).sort((a, b) => a.cluster_id.localeCompare(b.cluster_id));
  },

  siteLabel(clusterId, group) {
    const known = this.KNOWN_SITES[clusterId];
    if (known) return known.title;
    const home = group.roles.home;
    if (home?.node_url) {
      try {
        const u = new URL(home.node_url);
        return `${clusterId} · :${u.port || "?"}`;
      } catch (_) { /* ignore */ }
    }
    return clusterId;
  },

  siteHint(clusterId) {
    return this.KNOWN_SITES[clusterId]?.hint || "";
  },

  roleStatus(node) {
    if (!node) return "off";
    const trust = String(node.trust_status || "trusted").toLowerCase();
    if (trust === "compromised" || trust === "suspended") return "bad";
    const ping = node.ping || {};
    const reach = node.reachability || node.status || "offline";
    if (!ping.reachable && reach !== "online") return "off";
    if (trust === "pending") return "warn";
    const healthStatus = ping.health_status || ping.runtime_status;
    if (healthStatus === "overloaded" || healthStatus === "critical" || healthStatus === "busy") {
      return "warn";
    }
    if (!ping.reachable) return "bad";
    return "ok";
  },

  roleIcon(role, status, node) {
    const meta = this.ROLE_META[role] || { label: role, icon: "•" };
    const titles = {
      off: "выключено",
      ok: "работает",
      warn: "нагрузка / ожидание",
      bad: "ошибка",
    };
    const ping = node?.ping;
    const extra = ping?.reachable && ping.ms != null ? ` · ${Math.round(ping.ms)} ms` : "";
    return `<span class="role-icon role-icon-${status}" title="${meta.label}: ${titles[status]}${extra}">${meta.icon}</span>`;
  },

  clusterOverall(group) {
    const statuses = this.WORKER_ROLES.map((r) => this.roleStatus(group.roles[r]));
    if (statuses.some((s) => s === "bad")) return "bad";
    if (statuses.some((s) => s === "warn")) return "warn";
    if (statuses.some((s) => s === "ok")) return "ok";
    return "off";
  },

  renderDeploymentsList(container, localClusterId) {
    if (!container) return;
    const items = Object.entries(this.KNOWN_SITES).map(([id, meta]) => {
      const isHere = id === (localClusterId || "default");
      return `<li class="${isHere ? "deploy-here" : ""}"><strong>${meta.title}</strong> — ${meta.hint}${isHere ? " · <em>эта панель</em>" : ""}</li>`;
    });
    items.push("<li>Другие — свой <code>CLUSTER_ID</code> и порт в <code>.env</code></li>");
    container.innerHTML = items.join("");
  },
};
