(function () {
  const TRUST_RU = {
    trusted: "Доверена",
    pending: "Ожидает",
    suspended: "Отключена",
    compromised: "Скомпрометирована",
    unknown: "Неизвестно",
  };

  const discoveryUrl = document.getElementById("discoveryUrl");
  const adminSecret = document.getElementById("adminSecret");
  const tbody = document.getElementById("nodesBody");
  const pendingBody = document.getElementById("pendingBody");
  const pendingSection = document.getElementById("pendingSection");
  const pendingCount = document.getElementById("pendingCount");
  const status = document.getElementById("status");
  const secretWarning = document.getElementById("secretWarning");
  const modeHint = document.getElementById("enrollmentModeHint");
  const modeBanner = document.getElementById("modeBanner");
  const modeBannerTitle = document.getElementById("modeBannerTitle");

  const URL_KEY = "enrollment_discovery_url";

  const savedUrl = localStorage.getItem(URL_KEY);
  if (savedUrl) discoveryUrl.value = savedUrl;
  const savedSecret = sessionStorage.getItem(AdminTrust.SECRET_KEY);
  if (savedSecret) adminSecret.value = savedSecret;

  function headers() {
    return AdminTrust.headers(adminSecret.value);
  }

  function apiBase() {
    return AdminTrust.apiBase(discoveryUrl.value.trim());
  }

  function trustLabel(trust) {
    return TRUST_RU[trust] || trust;
  }

  async function loadHints() {
    try {
      const hints = await AdminApi.getEnrollmentHints();
      if (!discoveryUrl.value.trim() && hints.discovery_node_url) {
        discoveryUrl.value = hints.discovery_node_url;
      }
      const mode = hints.enrollment_mode || "legacy";
      if (hints.legacy_mode) {
        modeBannerTitle.textContent = "Сейчас режим legacy — автодоверие";
        modeHint.textContent =
          "Новые ноды сразу trusted. Запросов «разрешить подключение» нет. "
          + "Эта страница нужна только если хотите вручную отключить ноду (suspend) при злоупотреблении. "
          + "Чтобы включить ручное одобрение — поставьте ENROLLMENT_MODE=hybrid или strict в .env.";
        modeBanner.classList.add("mode-legacy");
      } else {
        modeBannerTitle.textContent = `Режим ${mode} — нужно одобрение`;
        modeHint.textContent =
          "Новые node_id попадают в pending, пока оператор не нажмёт «Принять». "
          + "Отклонение = оставить pending (нода не в публичном каталоге). Пользователи на своих Home Node не блокируются.";
        modeBanner.classList.remove("mode-legacy");
      }
      secretWarning.classList.toggle("hidden", hints.admin_secret_configured);
    } catch (e) {
      modeHint.textContent = "Не удалось прочитать подсказки: " + e.message;
    }
  }

  async function loadNodes() {
    const res = await fetch(`${apiBase()}&path=${encodeURIComponent("/admin/registry/nodes")}`, { headers: headers() });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function loadAuditHistory() {
    const body = document.getElementById("auditBody");
    if (!body || !adminSecret.value.trim()) return;
    try {
      const res = await fetch(
        `${apiBase()}&path=${encodeURIComponent("/admin/audit/history")}&limit=50`,
        { headers: headers() },
      );
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      const entries = data.entries || [];
      if (!entries.length) {
        body.innerHTML = '<tr><td colspan="5" class="empty">Пока нет записей</td></tr>';
        return;
      }
      body.innerHTML = entries.map((e) => `
        <tr>
          <td><code>${AdminUi.escapeHtml(e.created_at?.slice(0, 19) || "—")}</code></td>
          <td>${AdminUi.escapeHtml(e.actor)}</td>
          <td><strong>${AdminUi.escapeHtml(e.action)}</strong></td>
          <td><code>${AdminUi.escapeHtml(e.node_id)}</code></td>
          <td class="muted-xs">${AdminUi.escapeHtml(e.detail || e.cluster_id || "—")}</td>
        </tr>`).join("");
    } catch (e) {
      body.innerHTML = `<tr><td colspan="5" class="empty">${AdminUi.escapeHtml(e.message)}</td></tr>`;
    }
  }

  async function action(path, method = "POST", body = undefined) {
    return AdminTrust.request(discoveryUrl.value.trim(), path, {
      method,
      secret: adminSecret.value,
      body,
    });
  }

  function renderPending(nodes) {
    const pending = nodes.filter((n) => (n.trust_status || "") === "pending");
    pendingCount.textContent = String(pending.length);
    pendingSection.classList.toggle("hidden", pending.length === 0);
    if (!pending.length) {
      pendingBody.innerHTML = "";
      return;
    }
    pendingBody.innerHTML = pending.map((n) => {
      const role = (n.capabilities || [])[0] || "node";
      return `
        <tr>
          <td><span class="node-id">${AdminUi.escapeHtml(n.node_id)}</span></td>
          <td>${AdminUi.rolePill(role)}</td>
          <td><code>${AdminUi.escapeHtml(n.cluster_id || "default")}</code></td>
          <td class="actions-cell">
            <button type="button" class="btn-primary btn-xs" data-action="approve" data-id="${AdminUi.escapeHtml(n.node_id)}">Принять</button>
            <span class="muted-xs">или оставьте pending</span>
          </td>
        </tr>`;
    }).join("");
  }

  function renderAll(nodes) {
    if (!nodes.length) {
      tbody.innerHTML = '<tr><td colspan="5" class="empty">Нет зарегистрированных нод</td></tr>';
      return;
    }
    tbody.innerHTML = nodes.map((n) => {
      const trust = n.trust_status || "unknown";
      const reach = n.reachability || n.status || "offline";
      const role = (n.capabilities || [])[0] || "node";
      const actions = [];
      if (trust === "pending") {
        actions.push(`<button type="button" class="btn-primary btn-xs" data-action="approve" data-id="${AdminUi.escapeHtml(n.node_id)}">Принять</button>`);
      }
      if (trust === "trusted") {
        actions.push(`<button type="button" class="btn-secondary btn-xs" data-action="suspend" data-id="${AdminUi.escapeHtml(n.node_id)}" title="Убрать из инфраструктуры, не бан пользователей">Отключить</button>`);
        actions.push(`<button type="button" class="btn-danger btn-xs" data-action="compromise" data-id="${AdminUi.escapeHtml(n.node_id)}">Скомпрометирована</button>`);
      }
      if (trust === "suspended") {
        actions.push(`<button type="button" class="btn-secondary btn-xs" data-action="reinstate" data-id="${AdminUi.escapeHtml(n.node_id)}">Включить снова</button>`);
      }
      return `
        <tr>
          <td>${AdminUi.trustPill(trust, trustLabel(trust))}</td>
          <td><span class="node-id">${AdminUi.escapeHtml(n.node_id)}</span></td>
          <td>${AdminUi.rolePill(role)}</td>
          <td>${AdminUi.statusPill(reach, reach === "online" ? "Онлайн" : "Оффлайн")}</td>
          <td class="actions-cell">${actions.join("") || "—"}</td>
        </tr>`;
    }).join("");
  }

  async function refresh() {
    try {
      const data = await loadNodes();
      const nodes = data.nodes || [];
      renderPending(nodes);
      renderAll(nodes);
      await loadAuditHistory();
      AdminApi.showStatus(status, `Загружено: ${nodes.length} нод`);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
      tbody.innerHTML = `<tr><td colspan="5" class="empty">${AdminUi.escapeHtml(e.message)}</td></tr>`;
      pendingSection.classList.add("hidden");
    }
  }

  async function checkAccess() {
    if (!adminSecret.value.trim()) {
      AdminUi.setFieldCheck("access", { ok: false, message: "✗ Введите DISCOVERY_ADMIN_SECRET" });
      return;
    }
    AdminUi.setFieldCheck("access", { loading: true, message: "Проверка…" });
    try {
      await loadNodes();
      AdminUi.setFieldCheck("access", { ok: true, message: "✓ Доступ есть" });
    } catch (e) {
      AdminUi.setFieldCheck("access", { ok: false, message: `✗ ${e.message}` });
    }
  }

  function handleActionClick(ev) {
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
    const labels = {
      approve: "Принять ноду в сеть?",
      suspend: "Отключить ноду от инфраструктуры? Пользователи на своих Home Node не пострадают.",
      reinstate: "Снова доверить этой ноде?",
      compromise: "Отозвать доступ (compromise)? Нода потребует повторного approve.",
    };
    if (labels[act] && !window.confirm(labels[act])) return;

    const bodies = {
      suspend: { reason: "operator suspend" },
    };
    action(paths[act], "POST", bodies[act])
      .then((res) => {
        AdminApi.showStatus(status, res.message || "Готово");
        return refresh();
      })
      .catch((e) => AdminApi.showStatus(status, e.message, false));
  }

  tbody.addEventListener("click", handleActionClick);
  pendingBody.addEventListener("click", handleActionClick);
  document.getElementById("checkAccessBtn").addEventListener("click", checkAccess);

  const operatorId = document.getElementById("operatorId");
  if (operatorId) {
    operatorId.value = AdminTrust.operatorId();
    operatorId.addEventListener("change", () => AdminTrust.setOperatorId(operatorId.value));
  }

  async function init() {
    await loadHints();
    await refresh();
  }

  AdminToolbar.init(init);
})();
