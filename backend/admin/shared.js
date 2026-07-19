/** Shared helpers for Admin GUI pages. */
const AdminApi = {
  async getConfig() {
    const res = await fetch("/api/config");
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async saveNode(node) {
    const res = await fetch("/api/config/node", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(node),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async saveStorage(storage) {
    const res = await fetch("/api/config/storage", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(storage),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async reloadMedia() {
    const res = await fetch("/api/storage/reload-media", { method: "POST" });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  async runBackup() {
    const res = await fetch("/api/storage/backup", { method: "POST" });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  },

  showStatus(el, message, ok = true) {
    el.textContent = message;
    el.className = ok ? "status-msg ok" : "status-msg err";
  },
};

function bindNav() {
  const path = location.pathname.replace(/\/$/, "") || "/";
  document.querySelectorAll(".site-nav a").forEach((a) => {
    const href = a.getAttribute("href");
    if (href === path || (path === "/" && href === "/")) {
      a.classList.add("active");
    }
  });
}

document.addEventListener("DOMContentLoaded", bindNav);
