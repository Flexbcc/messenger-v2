/** Base path when Operator Console is mounted at /ops on main-node (:9205). */
const AdminBase = {
  prefix() {
    if (typeof window.__ADMIN_BASE === "string") return window.__ADMIN_BASE;
    return location.pathname.startsWith("/ops") ? "/ops" : "";
  },
  url(path) {
    const p = path.startsWith("/") ? path : `/${path}`;
    return `${this.prefix()}${p}`;
  },
};

/** CPU/RAM alert thresholds (operator-tunable, stored locally). */
const AdminAlerts = {
  STORAGE_KEY: "admin_alert_thresholds",
  defaults: { cpu: 85, ram: 90, disk: 95 },

  load() {
    try {
      return { ...this.defaults, ...JSON.parse(localStorage.getItem(this.STORAGE_KEY) || "{}") };
    } catch (_) {
      return { ...this.defaults };
    }
  },

  save(thresholds) {
    localStorage.setItem(this.STORAGE_KEY, JSON.stringify({ ...this.load(), ...thresholds }));
  },

  check(metrics) {
    if (!metrics) return [];
    const t = this.load();
    const alerts = [];
    if (metrics.cpu_percent_est != null && metrics.cpu_percent_est >= t.cpu) {
      alerts.push({ kind: "cpu", value: metrics.cpu_percent_est, limit: t.cpu });
    }
    if (metrics.ram_percent != null && metrics.ram_percent >= t.ram) {
      alerts.push({ kind: "ram", value: metrics.ram_percent, limit: t.ram });
    }
    if (metrics.disk_percent != null && metrics.disk_percent >= t.disk) {
      alerts.push({ kind: "disk", value: metrics.disk_percent, limit: t.disk });
    }
    return alerts;
  },

  renderBanner(container, alerts) {
    if (!container) return;
    if (!alerts.length) {
      container.classList.add("hidden");
      container.innerHTML = "";
      return;
    }
    container.classList.remove("hidden");
    container.innerHTML = `<strong>⚠ Нагрузка</strong> ${alerts.map((a) =>
      `${a.kind.toUpperCase()} ${a.value}% (порог ${a.limit}%)`).join(" · ")}`;
  },
};

const AdminTrust = {
  OPERATOR_KEY: "operator_id",
  SECRET_KEY: "enrollment_admin_secret",
  URL_KEY: "enrollment_discovery_url",

  operatorId() {
    return localStorage.getItem(this.OPERATOR_KEY) || "operator";
  },

  setOperatorId(id) {
    localStorage.setItem(this.OPERATOR_KEY, (id || "operator").trim() || "operator");
  },

  headers(secret) {
    sessionStorage.setItem(this.SECRET_KEY, secret);
    return {
      "Content-Type": "application/json",
      "X-Discovery-Admin-Secret": secret,
      "X-Operator-Id": this.operatorId(),
    };
  },

  apiBase(discoveryUrl) {
    const base = discoveryUrl.trim().replace(/\/$/, "");
    localStorage.setItem(this.URL_KEY, base);
    return `${AdminBase.url("/api/enrollment/proxy")}?discovery_url=${encodeURIComponent(base)}`;
  },

  async request(discoveryUrl, path, { method = "POST", secret, body = null } = {}) {
    if (!secret?.trim()) throw new Error("DISCOVERY_ADMIN_SECRET required");
    const opts = { method, headers: this.headers(secret.trim()) };
    if (body != null && method !== "GET") {
      opts.body = typeof body === "string" ? body : JSON.stringify(body);
    }
    const res = await fetch(`${this.apiBase(discoveryUrl)}&path=${encodeURIComponent(path)}`, opts);
    if (!res.ok) {
      const text = await res.text();
      throw new Error(text || `HTTP ${res.status}`);
    }
    return res.json();
  },
};

/** Shared toolbar + inline check feedback for Operator Admin. */
const AdminToolbar = {
  init(onRefresh, opts = {}) {
    const refreshBtn = document.getElementById("refreshBtn");
    if (refreshBtn && typeof onRefresh === "function") {
      refreshBtn.addEventListener("click", () => onRefresh());
    }
    const auto = document.getElementById("autoRefreshLabel");
    if (auto) {
      auto.classList.toggle("hidden", !opts.autoRefresh);
    }
  },
};

/** Shared helpers for Admin GUI pages. */
const AdminTheme = {
  STORAGE_KEY: "admin_theme",

  init() {
    const saved = localStorage.getItem(this.STORAGE_KEY);
    if (saved === "light" || saved === "dark") {
      document.documentElement.setAttribute("data-theme", saved);
    }
    const btn = document.getElementById("themeToggle");
    if (btn) {
      btn.addEventListener("click", () => {
        const current = document.documentElement.getAttribute("data-theme");
        const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        const isDark = current === "dark" || (!current && prefersDark);
        const next = isDark ? "light" : "dark";
        document.documentElement.setAttribute("data-theme", next);
        localStorage.setItem(this.STORAGE_KEY, next);
      });
    }
  },
};

const AdminApi = {
  async getConfig() {
    const res = await fetch(AdminBase.url("/api/config"));
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async getEnrollmentHints() {
    const res = await fetch(AdminBase.url("/api/enrollment/hints"));
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async saveNode(node) {
    const res = await fetch(AdminBase.url("/api/config/node"), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(node),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async saveStorage(storage) {
    const res = await fetch(AdminBase.url("/api/config/storage"), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(storage),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async reloadMedia() {
    const res = await fetch(AdminBase.url("/api/storage/reload-media"), { method: "POST" });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async runBackup() {
    const res = await fetch(AdminBase.url("/api/storage/backup"), { method: "POST" });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async checkHealth(url, role = "") {
    const res = await fetch(AdminBase.url("/api/check/health"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, role }),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async checkDiscovery(url) {
    const res = await fetch(AdminBase.url("/api/check/discovery"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async checkSetup(payload) {
    const res = await fetch(AdminBase.url("/api/check/setup"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async checkMedia(url) {
    const res = await fetch(AdminBase.url("/api/check/media"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: url || "" }),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async applyConfig(services) {
    const res = await fetch(AdminBase.url("/api/services/apply-config"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ services: services || null }),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async getServicesStatus() {
    const res = await fetch(AdminBase.url("/api/services/status"));
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  showStatus(el, message, ok = true) {
    if (!el) return;
    el.textContent = message;
    el.className = ok ? "status-msg ok" : "status-msg err";
  },
};

const AdminUi = {
  escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  },

  formatCheckDetail(c) {
    if (!c || !c.ok) return c?.error || "недоступен";
    return [
      c.latency_ms != null ? `${c.latency_ms} мс` : null,
      c.node_id ? c.node_id : null,
      c.registered_nodes != null ? `${c.registered_nodes} нод в каталоге` : null,
      c.node_role ? c.node_role : null,
    ].filter(Boolean).join(" · ") || "OK";
  },

  setFieldCheck(key, state) {
    const el = document.querySelector(`[data-check-for="${key}"]`);
    if (!el) return;
    el.classList.remove("ok", "fail", "pending", "hidden");
    if (state.hidden) {
      el.classList.add("hidden");
      el.textContent = "";
      return;
    }
    if (state.loading) {
      el.classList.add("pending");
      el.textContent = state.message || "Проверка…";
      return;
    }
    el.classList.add(state.ok ? "ok" : "fail");
    el.textContent = state.message || (state.ok ? "OK" : "Ошибка");
  },

  rolePill(role) {
    const r = String(role || "node").toLowerCase();
    const labels = {
      home: "Home", relay: "Relay", storage: "Storage", media: "Media",
      discovery: "Discovery", witness: "Witness", gateway: "Gateway", turn: "TURN",
    };
    const label = labels[r] || r;
    return `<span class="role-pill role-${AdminUi.escapeHtml(r)}">${AdminUi.escapeHtml(label)}</span>`;
  },

  trustPill(trust) {
    const t = String(trust || "unknown").toLowerCase();
    return `<span class="trust-pill trust-${AdminUi.escapeHtml(t)}">${AdminUi.escapeHtml(t)}</span>`;
  },

  statusPill(status, label) {
    const s = String(status || "offline").toLowerCase();
    const cls = {
      online: "status-online", offline: "status-offline",
      normal: "status-normal", busy: "status-busy",
      overloaded: "status-overloaded", critical: "status-critical",
    }[s] || "status-offline";
    return `<span class="status-pill ${cls}">${AdminUi.escapeHtml(label || status)}</span>`;
  },
};

function bindNav() {
  const path = location.pathname.replace(/\/$/, "");
  document.querySelectorAll(".site-nav a").forEach((a) => {
    const href = a.getAttribute("href");
    if (!href || href.startsWith("http")) return;
    const target = new URL(href, location.href).pathname.replace(/\/$/, "");
    if (target === path) a.classList.add("active");
  });
}

document.addEventListener("DOMContentLoaded", () => {
  bindNav();
  AdminTheme.init();
});
