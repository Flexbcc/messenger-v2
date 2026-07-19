(function () {
  const discoveryUrl = document.getElementById("discoveryUrl");
  const adminSecret = document.getElementById("adminSecret");
  const refreshBtn = document.getElementById("refreshBtn");
  const tbody = document.getElementById("nodesBody");
  const status = document.getElementById("status");

  const URL_KEY = "enrollment_discovery_url";
  const SECRET_KEY = "enrollment_admin_secret";

  const savedUrl = localStorage.getItem(URL_KEY);
  if (savedUrl) discoveryUrl.value = savedUrl;
  const savedSecret = sessionStorage.getItem(SECRET_KEY);
  if (savedSecret) adminSecret.value = savedSecret;

  async function initDiscoveryUrl() {
    if (discoveryUrl.value.trim()) return;
    try {
      const cfg = await fetch("/api/config").then((r) => r.json());
      const url = cfg?.node?.discovery_node_url || cfg?.discovery_public_url;
      if (url) discoveryUrl.value = url;
    } catch (_) {
      /* user fills manually */
    }
  }

  function headers() {
    sessionStorage.setItem(SECRET_KEY, adminSecret.value);
    return {
      "Content-Type": "application/json",
      "X-Discovery-Admin-Secret": adminSecret.value,
    };
  }

  function apiBase() {
    const base = discoveryUrl.value.trim().replace(/\/$/, "");
    localStorage.setItem(URL_KEY, base);
    return `/api/enrollment/proxy?discovery_url=${encodeURIComponent(base)}`;
  }

  async function loadNodes() {
    const res = await fetch(`${apiBase()}&path=/admin/registry/nodes`, { headers: headers() });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function action(path, method = "POST") {
    const res = await fetch(`${apiBase()}&path=${encodeURIComponent(path)}`, {
      method,
      headers: headers(),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function render(nodes) {
    if (!nodes.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="empty">Нет зарегистрированных нод</td></tr>';
      return;
    }
    tbody.innerHTML = nodes.map((n) => {
      const trust = n.trust_status || "unknown";
      const reach = n.reachability || n.status || "offline";
      const actions = [];
      if (trust === "pending") {
        actions.push(`<button type="button" data-action="approve" data-id="${escapeHtml(n.node_id)}">Approve</button>`);
      }
      if (trust === "trusted") {
        actions.push(`<button type="button" data-action="suspend" data-id="${escapeHtml(n.node_id)}">Suspend</button>`);
        actions.push(`<button type="button" data-action="compromise" data-id="${escapeHtml(n.node_id)}">Compromise</button>`);
      }
      if (trust === "suspended") {
        actions.push(`<button type="button" data-action="reinstate" data-id="${escapeHtml(n.node_id)}">Reinstate</button>`);
      }
      return `
        <tr>
          <td><code class="trust-${trust}">${escapeHtml(trust)}</code></td>
          <td><code>${escapeHtml(n.node_id)}</code></td>
          <td>${(n.capabilities || []).map(escapeHtml).join(", ")}</td>
          <td><code>${escapeHtml(n.node_url)}</code></td>
          <td>${escapeHtml(reach)}</td>
          <td class="actions-cell">${actions.join(" ") || "—"}</td>
        </tr>`;
    }).join("");
  }

  async function refresh() {
    try {
      const data = await loadNodes();
      render(data.nodes || []);
      AdminApi.showStatus(status, `Загружено: ${(data.nodes || []).length} нод`);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
      tbody.innerHTML = `<tr><td colspan="6" class="empty">${escapeHtml(e.message)}</td></tr>`;
    }
  }

  tbody.addEventListener("click", async (ev) => {
    const btn = ev.target.closest("button[data-action]");
    if (!btn) return;
    const id = btn.dataset.id;
    const act = btn.dataset.action;
    const paths = {
      approve: `/admin/registry/nodes/${id}/approve`,
      suspend: `/admin/registry/nodes/${id}/suspend`,
      reinstate: `/admin/registry/nodes/${id}/reinstate`,
      compromise: `/admin/registry/nodes/${id}/compromise`,
    };
    try {
      const res = await action(paths[act]);
      AdminApi.showStatus(status, res.message || `${act} OK`);
      await refresh();
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  refreshBtn.addEventListener("click", refresh);
  initDiscoveryUrl().then(refresh);
})();
