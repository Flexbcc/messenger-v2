(function () {
  const TOKEN_KEY = "operator_secret";

  const loginScreen = document.getElementById("loginScreen");
  const app = document.getElementById("app");
  const secretInput = document.getElementById("secretInput");
  const loginError = document.getElementById("loginError");
  const statusMsg = document.getElementById("statusMsg");
  const summaryCards = document.getElementById("summaryCards");
  const featureFlags = document.getElementById("featureFlags");
  const deployMeta = document.getElementById("deployMeta");
  const servicesBody = document.getElementById("servicesBody");
  const nodesBody = document.getElementById("nodesBody");
  const actionOutput = document.getElementById("actionOutput");
  const deployLog = document.getElementById("deployLog");
  const logServiceSelect = document.getElementById("logServiceSelect");

  let authRequired = false;
  let lastDashboard = null;

  function token() {
    return sessionStorage.getItem(TOKEN_KEY) || "";
  }

  function setToken(v) {
    if (v) sessionStorage.setItem(TOKEN_KEY, v);
    else sessionStorage.removeItem(TOKEN_KEY);
  }

  function headers(json = false) {
    const h = {};
    if (json) h["Content-Type"] = "application/json";
    const t = token();
    if (t) h["X-Operator-Token"] = t;
    return h;
  }

  function showStatus(text, ok = true) {
    statusMsg.textContent = text;
    statusMsg.className = ok ? "status ok" : "status err";
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function fmtBytes(n) {
    const v = Number(n) || 0;
    if (v < 1024) return `${v} B`;
    if (v < 1024 ** 2) return `${(v / 1024).toFixed(1)} KB`;
    if (v < 1024 ** 3) return `${(v / 1024 ** 2).toFixed(1)} MB`;
    return `${(v / 1024 ** 3).toFixed(2)} GB`;
  }

  async function api(path, opts = {}) {
    const { json, headers: extraHeaders, ...fetchOpts } = opts;
    const res = await fetch(path, {
      ...fetchOpts,
      headers: { ...headers(!!json), ...(extraHeaders || {}) },
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 401) {
      setToken("");
      showLogin();
      throw new Error("Сессия истекла — войдите снова");
    }
    if (!res.ok) throw new Error(data.error || data.output || res.statusText);
    return data;
  }

  function showLogin() {
    loginScreen.classList.remove("hidden");
    app.classList.add("hidden");
  }

  function showApp() {
    loginScreen.classList.add("hidden");
    app.classList.remove("hidden");
  }

  async function initAuth() {
    const cfg = await fetch("/api/config").then((r) => r.json());
    authRequired = !!cfg.auth_required;
    if (!authRequired) {
      showApp();
      return;
    }
    if (token()) {
      try {
        await api("/api/dashboard");
        showApp();
        return;
      } catch (_) {
        setToken("");
      }
    }
    showLogin();
  }

  async function login() {
    loginError.textContent = "";
    const secret = secretInput.value.trim();
    if (!secret) {
      loginError.textContent = "Введите ключ";
      return;
    }
    const res = await fetch("/api/auth/verify", {
      method: "POST",
      headers: headers(true),
      body: JSON.stringify({ secret }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) {
      loginError.textContent = data.error || "Неверный ключ";
      return;
    }
    setToken(secret);
    secretInput.value = "";
    showApp();
    await refresh();
  }

  function renderSummary(s) {
    const items = [
      ["Пользователи (home)", s.home_users],
      ["Регистрация (discovery)", s.registered_users_discovery],
      ["Устройства", s.devices],
      ["Диалоги", s.conversations],
      ["Сообщения", s.messages],
      ["Онлайн сейчас", s.online_users_now],
      ["WS подключения", s.ws_connections],
      ["Ноды trusted", s.nodes_trusted],
      ["Ноды online", s.nodes_online],
      ["Медиа файлов", s.media_files],
      ["Медиа объём", fmtBytes(s.media_bytes)],
    ];
    summaryCards.innerHTML = items.map(([label, val]) => `
      <div class="card ok">
        <div class="name">${esc(label)}</div>
        <div class="state">${esc(val)}</div>
      </div>`).join("");
  }

  function renderFeatures(f) {
    const labels = {
      messaging: "Обмен сообщениями",
      multi_device: "Несколько устройств",
      media_uploads: "Загрузка медиа",
      realtime_ws: "Realtime (WebSocket)",
      federation_nodes: "Федерация нод",
    };
    featureFlags.innerHTML = Object.entries(labels).map(([k, label]) => {
      const on = !!f[k];
      return `<div class="feature ${on ? "on" : "off"}">
        <span class="dot"></span>
        <span>${esc(label)}</span>
        <span class="hint">${on ? "используется" : "пока нет"}</span>
      </div>`;
    }).join("");
  }

  function renderServices(services) {
    if (!services.length) {
      servicesBody.innerHTML = '<tr><td colspan="5">нет данных</td></tr>';
      return;
    }
    servicesBody.innerHTML = services.map((s) => {
      const health = s.health_ok === null ? "—" : (s.health_ok ? "ok" : "fail");
      const docker = s.running ? "Up" : "Down";
      return `<tr>
        <td><code>${esc(s.node_id)}</code></td>
        <td>${esc(s.host_alias)}</td>
        <td class="${s.running ? "ok-text" : "bad-text"}">${esc(docker)}</td>
        <td class="${s.health_ok ? "ok-text" : "bad-text"}">${esc(health)}</td>
        <td class="actions">
          <button type="button" data-restart="${esc(s.node_id)}">Restart</button>
          <button type="button" data-logs="${esc(s.node_id)}">Лог</button>
        </td>
      </tr>`;
    }).join("");

    const opts = services.map((s) => `<option value="${esc(s.node_id)}">${esc(s.node_id)}</option>`).join("");
    logServiceSelect.innerHTML = opts;
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
      const data = await api("/api/dashboard");
      lastDashboard = data;
      renderSummary(data.summary || {});
      renderFeatures(data.features || {});
      renderServices(data.services || []);
      renderNodes(data.nodes || []);
      const d = data.deploy || {};
      deployMeta.textContent = `git ${d.git_head || "?"} · webhook ${d.webhook || "?"} · ${d.status || ""}`;
      showStatus(`Обновлено ${new Date().toLocaleTimeString()}`);
    } catch (e) {
      showStatus(e.message, false);
    }
  }

  async function runAction(path, body, label, outEl = actionOutput) {
    showStatus(`${label}…`, true);
    document.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    try {
      const res = await api(path, {
        method: "POST",
        json: true,
        body: JSON.stringify(body || {}),
      });
      showStatus(res.ok ? `${label} OK` : `${label} ошибка`, !!res.ok);
      if (res.output) outEl.textContent = res.output;
      await refresh();
    } catch (e) {
      showStatus(e.message, false);
    } finally {
      document.querySelectorAll("button").forEach((b) => { b.disabled = false; });
    }
  }

  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
      document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
      tab.classList.add("active");
      document.getElementById(`tab-${tab.dataset.tab}`).classList.add("active");
    });
  });

  document.getElementById("btnLogin").addEventListener("click", login);
  secretInput.addEventListener("keydown", (e) => { if (e.key === "Enter") login(); });
  document.getElementById("btnLogout").addEventListener("click", () => {
    setToken("");
    showLogin();
  });

  document.getElementById("btnRefresh").addEventListener("click", refresh);
  document.getElementById("btnPush").addEventListener("click", () => runAction("/api/deploy/push", {}, "Push"));
  document.getElementById("btnDeploy").addEventListener("click", () => runAction("/api/deploy/trigger", {}, "Deploy"));
  document.getElementById("btnEnsure").addEventListener("click", () => runAction("/api/deploy/ensure", {}, "Ensure autodeploy"));
  document.getElementById("btnApproveAll").addEventListener("click", () => runAction("/api/enrollment/approve", {}, "Approve all"));
  document.getElementById("btnUpdateMain").addEventListener("click", () => runAction("/api/node/update", { host: "main" }, "node-update main"));
  document.getElementById("btnUpdateWorker").addEventListener("click", () => runAction("/api/node/update", { host: "worker" }, "node-update worker"));

  document.getElementById("btnLoadDeployLog").addEventListener("click", async () => {
    try {
      const log = await api("/api/deploy/log?lines=120");
      deployLog.textContent = log.log || "(пусто)";
    } catch (e) {
      deployLog.textContent = e.message;
    }
  });

  document.getElementById("btnLoadServiceLog").addEventListener("click", async () => {
    const svc = logServiceSelect.value;
    try {
      const log = await api(`/api/node/logs?service=${encodeURIComponent(svc)}&lines=120`);
      deployLog.textContent = log.log || "(пусто)";
    } catch (e) {
      deployLog.textContent = e.message;
    }
  });

  servicesBody.addEventListener("click", async (ev) => {
    const restart = ev.target.closest("button[data-restart]");
    const logs = ev.target.closest("button[data-logs]");
    if (restart) {
      await runAction("/api/node/restart", { service: restart.dataset.restart }, `Restart ${restart.dataset.restart}`);
      return;
    }
    if (logs) {
      const svc = logs.dataset.logs;
      document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
      document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
      document.querySelector('.tab[data-tab="logs"]').classList.add("active");
      document.getElementById("tab-logs").classList.add("active");
      logServiceSelect.value = svc;
      try {
        const log = await api(`/api/node/logs?service=${encodeURIComponent(svc)}&lines=120`);
        deployLog.textContent = log.log || "(пусто)";
      } catch (e) {
        deployLog.textContent = e.message;
      }
    }
  });

  nodesBody.addEventListener("click", async (ev) => {
    const btn = ev.target.closest("button[data-approve]");
    if (!btn) return;
    await runAction("/api/enrollment/approve-one", { node_id: btn.dataset.approve }, `Approve ${btn.dataset.approve}`);
  });

  document.getElementById("btnCreateInvite").addEventListener("click", async () => {
    const label = document.getElementById("inviteLabel").value.trim();
    const ttl = parseInt(document.getElementById("inviteTtl").value, 10) || 300;
    showStatus("Создаём invite…");
    try {
      const res = await api("/api/invite/create", {
        method: "POST",
        json: true,
        body: JSON.stringify({ label: label || undefined, ttl_seconds: ttl }),
      });
      const box = document.getElementById("inviteResult");
      const url = res.join_url || "";
      document.getElementById("inviteUrl").textContent = url;
      document.getElementById("inviteExpires").textContent = `Истекает: ${res.expires_at || "?"}`;
      const qr = document.getElementById("inviteQr");
      qr.innerHTML = url
        ? `<img alt="QR" width="200" height="200" src="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${encodeURIComponent(url)}">`
        : "";
      box.classList.remove("hidden");
      showStatus("Invite создан — одноразовый");
    } catch (e) {
      showStatus(e.message, false);
    }
  });

  document.getElementById("btnCopyInvite").addEventListener("click", async () => {
    const url = document.getElementById("inviteUrl").textContent;
    try {
      await navigator.clipboard.writeText(url);
      showStatus("Скопировано");
    } catch (_) {
      showStatus("Не удалось скопировать", false);
    }
  });

  initAuth().then(() => refresh());
  setInterval(() => {
    if (!app.classList.contains("hidden")) refresh();
  }, 15000);
})();
