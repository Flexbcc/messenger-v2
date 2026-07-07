(function () {
  const healthCards = document.getElementById("healthCards");
  const nodesBody = document.getElementById("nodesBody");
  const deployLog = document.getElementById("deployLog");
  const statusMsg = document.getElementById("statusMsg");
  const configLine = document.getElementById("configLine");
  const deployMeta = document.getElementById("deployMeta");
  const autoRefresh = document.getElementById("autoRefresh");

  function showStatus(text, ok = true) {
    statusMsg.textContent = text;
    statusMsg.className = ok ? "status ok" : "status err";
  }

  async function api(path, opts = {}) {
    const res = await fetch(path, opts);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || data.output || res.statusText);
    return data;
  }

  function renderHealth(health) {
    healthCards.innerHTML = Object.entries(health).map(([name, h]) => `
      <div class="card ${h.ok ? "ok" : "bad"}">
        <div class="name">${name}</div>
        <div class="state">${h.ok ? "online" : "offline"}</div>
      </div>`).join("");
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function renderNodes(nodes) {
    if (!nodes.length) {
      nodesBody.innerHTML = '<tr><td colspan="6">нет нод</td></tr>';
      return;
    }
    nodesBody.innerHTML = nodes.map((n) => {
      const trust = n.trust_status || "?";
      const actions = trust === "pending"
        ? `<button type="button" data-approve="${esc(n.node_id)}">Approve</button>`
        : "—";
      return `<tr>
        <td><code class="trust-${trust}">${esc(trust)}</code></td>
        <td><code>${esc(n.node_id)}</code></td>
        <td>${(n.capabilities || []).map(esc).join(", ")}</td>
        <td><code>${esc(n.node_url)}</code></td>
        <td>${esc(n.reachability || n.status || "?")}</td>
        <td>${actions}</td>
      </tr>`;
    }).join("");
  }

  async function refresh() {
    try {
      const cfg = await api("/api/config");
      configLine.textContent = `main ${cfg.main_ip} · worker ${cfg.worker_ip} · webhook via Gitea push`;

      const st = await api("/api/status");
      renderHealth(st.health);
      renderNodes(st.nodes || []);
      deployMeta.textContent = `webhook: ${st.webhook} · ${st.deploy_status || ""}`;

      const log = await api("/api/deploy/log?lines=60");
      deployLog.textContent = log.log || "(пусто)";
      showStatus(`Обновлено ${new Date().toLocaleTimeString()}`);
    } catch (e) {
      showStatus(e.message, false);
    }
  }

  async function runAction(path, label) {
    showStatus(`${label}…`, true);
    document.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    try {
      const res = await api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      showStatus(res.ok ? `${label} OK` : `${label} ошибка`, res.ok);
      if (res.output) deployLog.textContent = res.output;
      await refresh();
    } catch (e) {
      showStatus(e.message, false);
    } finally {
      document.querySelectorAll("button").forEach((b) => { b.disabled = false; });
    }
  }

  document.getElementById("btnRefresh").addEventListener("click", refresh);
  document.getElementById("btnPush").addEventListener("click", () => runAction("/api/deploy/push", "Push"));
  document.getElementById("btnDeploy").addEventListener("click", () => runAction("/api/deploy/trigger", "Deploy"));
  document.getElementById("btnApprove").addEventListener("click", () => runAction("/api/enrollment/approve", "Approve"));

  nodesBody.addEventListener("click", async (ev) => {
    const btn = ev.target.closest("button[data-approve]");
    if (!btn) return;
    const node_id = btn.dataset.approve;
    showStatus(`Approve ${node_id}…`);
    try {
      await api("/api/enrollment/approve-one", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ node_id }),
      });
      await refresh();
      showStatus(`Approved ${node_id}`);
    } catch (e) {
      showStatus(e.message, false);
    }
  });

  refresh();
  setInterval(() => { if (autoRefresh.checked) refresh(); }, 10000);
})();
