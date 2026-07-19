(function () {
  const form = document.getElementById("setupForm");
  const status = document.getElementById("status");

  const fields = [
    "lan_ip", "discovery_node_url", "cluster_id", "node_resource_policy",
    "home_node_public_url", "storage_node_url", "media_node_public_url",
    "relay_node_public_url", "jwt_secret",
  ];

  async function load() {
    try {
      const cfg = await AdminApi.getConfig();
      const n = cfg.node;
      fields.forEach((f) => {
        if (form.elements[f]) form.elements[f].value = n[f] ?? "";
      });
      if (cfg.secrets?.jwt_secret_set && form.elements.jwt_secret) {
        form.elements.jwt_secret.placeholder = "•••••••• (не менять — оставьте пустым)";
        if (form.elements.jwt_secret.value === "••••••••••••••••") {
          form.elements.jwt_secret.value = "";
        }
      }
    } catch (e) {
      AdminApi.showStatus(status, "Не удалось загрузить конфиг: " + e.message, false);
    }
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const node = {};
    fields.forEach((f) => {
      const el = form.elements[f];
      if (f === "jwt_secret" && !el.value.trim()) {
        node[f] = "••••••••••••••••";
      } else {
        node[f] = el.value;
      }
    });
    try {
      const res = await AdminApi.saveNode(node);
      AdminApi.showStatus(status, res.message || "Сохранено: " + res.path);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  load();
})();
