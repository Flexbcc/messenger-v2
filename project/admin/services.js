(function () {
  const ROLE_ICONS = {
    home: "🏠",
    storage: "📦",
    media: "🎬",
    relay: "🔀",
    discovery: "🌐",
    turn: "📡",
    gateway: "🚪",
  };

  function escapeHtml(s) {
    return AdminUi.escapeHtml(s);
  }

  async function fetchStatus() {
    const res = await fetch(AdminBase.url("/api/services/status"));
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function runAction(service, action) {
    const res = await fetch(AdminBase.url(`/api/services/${encodeURIComponent(service)}/${action}`), {
      method: "POST",
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  function renderServices(container, data, opts = {}) {
    if (!container) return;
    const compact = !!opts.compact;
    if (!data.docker_available) {
      container.innerHTML = `<p class="services-hint">${escapeHtml(data.hint || "Docker недоступен")}</p>`;
      return;
    }
    const items = (data.services || []).filter((s) => !opts.only || opts.only.includes(s.name));
    if (!items.length) {
      container.innerHTML = '<p class="services-hint">Сервисы не найдены</p>';
      return;
    }
    container.innerHTML = items.map((svc) => {
      const icon = ROLE_ICONS[svc.role] || "⚙️";
      const stateCls = svc.running ? "svc-running" : "svc-stopped";
      const stateLabel = svc.running ? "Работает" : "Стоп";
      const optional = svc.optional ? '<span class="svc-tag">опц.</span>' : "";
      const actions = compact ? "" : (svc.running
        ? `<div class="service-actions">
            <button type="button" class="btn-secondary btn-xs svc-btn" data-svc="${escapeHtml(svc.name)}" data-act="restart" title="Перезапуск">↻</button>
            <button type="button" class="btn-ghost btn-xs svc-btn" data-svc="${escapeHtml(svc.name)}" data-act="stop" title="Остановить">⏹</button>
          </div>`
        : `<div class="service-actions">
            <button type="button" class="btn-primary btn-xs svc-btn" data-svc="${escapeHtml(svc.name)}" data-act="start">Запуск</button>
          </div>`);
      return `
        <article class="service-card ${stateCls}${compact ? " service-card-compact" : ""}">
          <div class="service-card-body">
            <div class="service-card-head">
              <span class="service-icon" aria-hidden="true">${icon}</span>
              <div class="service-card-meta">
                <strong>${escapeHtml(svc.label)}</strong>${optional}
                <span class="service-state">${escapeHtml(stateLabel)}${svc.port ? ` · :${svc.port}` : ""}</span>
              </div>
            </div>
            ${actions}
          </div>
        </article>`;
    }).join("");

    container.querySelectorAll(".svc-btn").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const svc = btn.dataset.svc;
        const act = btn.dataset.act;
        btn.disabled = true;
        try {
          await runAction(svc, act);
          const fresh = await fetchStatus();
          renderServices(container, fresh, opts);
          if (opts.onChange) opts.onChange(fresh);
        } catch (e) {
          alert(e.message);
        } finally {
          btn.disabled = false;
        }
      });
    });
  }

  function renderStatusRow(container, data, opts = {}) {
    if (!container) return;
    if (!data?.docker_available) {
      container.innerHTML = `<span class="services-hint">${escapeHtml(data?.hint || "Docker недоступен")}</span>`;
      return;
    }
    const items = (data.services || []).filter((s) => !opts.only || opts.only.includes(s.name));
    if (!items.length) {
      container.innerHTML = '<span class="services-hint">—</span>';
      return;
    }
    container.innerHTML = items.map((svc) => {
      const dot = svc.running ? "dot-on" : "dot-off";
      return `<span class="svc-chip ${dot}">${escapeHtml(svc.label)}</span>`;
    }).join("");
  }

  async function refreshContainer(container, opts) {
    try {
      const data = await fetchStatus();
      if (opts?.statusRow) {
        renderStatusRow(container, data, opts);
      } else {
        renderServices(container, data, opts);
      }
      return data;
    } catch (e) {
      if (container) {
        container.innerHTML = `<p class="services-hint err">${escapeHtml(e.message)}</p>`;
      }
      return null;
    }
  }

  window.AdminServices = {
    fetchStatus,
    renderServices,
    renderStatusRow,
    refreshContainer,
    runAction,
  };
})();
