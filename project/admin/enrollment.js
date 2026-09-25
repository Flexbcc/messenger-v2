(function () {
  const pendingBody = document.getElementById("pendingBody");
  const pendingSection = document.getElementById("pendingSection");
  const pendingCount = document.getElementById("pendingCount");
  const status = document.getElementById("status");
  const secretWarning = document.getElementById("secretWarning");
  const modeHint = document.getElementById("enrollmentModeHint");
  const modeBanner = document.getElementById("modeBanner");
  const modeBannerTitle = document.getElementById("modeBannerTitle");

  async function loadHints() {
    try {
      const hints = await AdminApi.getEnrollmentHints();
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
    const res = await fetch(AdminBase.url("/api/monitor/registry/nodes/all"));
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function action(nodeId, operation, body = undefined) {
    const res = await fetch(
      AdminBase.url(`/api/operator/registry/${encodeURIComponent(nodeId)}/${operation}`),
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Operator-Id": AdminTrust.operatorId(),
        },
        body: JSON.stringify(body || {}),
      },
    );
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  function renderPending(nodes) {
    const pending = nodes.filter((n) => (n.trust_status || "") === "pending");
    pendingCount.textContent = String(pending.length);
    if (!pending.length) {
      pendingBody.innerHTML = '<tr><td colspan="4" class="empty">Новых запросов нет</td></tr>';
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

  async function refresh() {
    try {
      const data = await loadNodes();
      const nodes = data.nodes || [];
      renderPending(nodes);
      AdminApi.showStatus(status, `Реестр доступен · всего ${nodes.length} нод`);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
      pendingBody.innerHTML = `<tr><td colspan="4" class="empty">${AdminUi.escapeHtml(e.message)}</td></tr>`;
    }
  }

  async function checkAccess() {
    AdminUi.setFieldCheck("access", { loading: true, message: "Проверка…" });
    try {
      await loadNodes();
      AdminUi.setFieldCheck("access", { ok: true, message: "✓ Доступ есть" });
    } catch (e) {
      AdminUi.setFieldCheck("access", { ok: false, message: `✗ ${e.message}` });
    }
  }

  async function handleActionClick(ev) {
    const btn = ev.target.closest("button[data-action]");
    if (!btn) return;
    const id = btn.dataset.id;
    const act = btn.dataset.action;
    const labels = {
      approve: "Принять ноду в сеть?",
      suspend: "Отключить ноду от инфраструктуры? Пользователи на своих Home Node не пострадают.",
      reinstate: "Снова доверить этой ноде?",
      compromise: "Отозвать доступ (compromise)? Нода потребует повторного approve.",
      "re-enroll": "Сбросить ноду в pending и выдать новый enrollment_secret? Старый node_token будет отозван — нода должна пройти enrollment заново.",
    };
    if (labels[act]) {
      const decision = await AdminDialog.confirm({
        title: "Решение о доверии",
        message: labels[act],
      });
      if (!decision.confirmed) return;
    }

    const bodies = {
      suspend: { reason: "operator suspend" },
    };
    try {
      const res = await action(id, act, bodies[act]);
      AdminApi.showStatus(status, res.message || "Готово");
      if (act === "re-enroll" && res.enrollment_secret) {
        await AdminDialog.info(
          `Новый секрет регистрации · ${id}`,
          `${res.enrollment_secret}\n\nПоказывается один раз. Передайте владельцу ноды.`,
        );
      }
      await refresh();
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  }

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
  AdminTheme.init();
  init();
})();
