(function () {
  const form = document.getElementById("setupForm");
  const WORKER_SERVICES = ["home-node", "storage-node", "media-node", "relay-node"];
  const svcOpts = { only: WORKER_SERVICES };
  const status = document.getElementById("status");
  const editBtn = document.getElementById("editConfigBtn");
  const cancelBtn = document.getElementById("cancelEditBtn");

  function setEditing(editing) {
    form.classList.toggle("is-editing", editing);
    form.classList.toggle("is-locked", !editing);
    form.querySelectorAll(".setup-block:not(.setup-services) input, .setup-block:not(.setup-services) select, .setup-block:not(.setup-services) textarea, #checkAllBtn, .btn-check")
      .forEach((el) => { el.disabled = !editing; });
    form.querySelectorAll(".config-action").forEach((el) => { el.disabled = !editing; });
    if (cancelBtn) cancelBtn.hidden = !editing;
    if (editBtn) editBtn.hidden = editing;
    const badge = document.getElementById("viewModeBadge");
    if (badge) badge.textContent = editing ? "Редактирование" : "Режим просмотра";
  }

  const fieldMap = {
    discovery: "discovery_node_url",
    home: "home_node_public_url",
    storage: "storage_node_url",
    media: "media_node_public_url",
    relay: "relay_node_public_url",
  };

  const textFields = [
    "lan_ip", "discovery_node_url", "discovery_quorum_urls", "discovery_public_urls",
    "discovery_minimum_sources", "cluster_id", "node_resource_policy",
    "owner_resource_percent",
    "relay_transport_mode", "relay_max_persistent_peers", "relay_link_idle_seconds",
    "peer_guard_count", "peer_rotating_count", "peer_reserve_count",
    "relay_ws_max_connections", "relay_ws_max_connections_per_peer",
    "direct_max_connections", "direct_max_keepalive_connections",
    "direct_keepalive_expiry_seconds",
  ];
  const boolFields = [
    "participate_relay", "participate_storage", "participate_witness",
    "participate_media_cache", "participate_nat_assist",
  ];

  const usageProfiles = {
    personal: {
      participate_relay: false, participate_storage: false,
      owner_resource_percent: 90, relay_max_persistent_peers: 5,
      peer_guard_count: 2, peer_rotating_count: 3, peer_reserve_count: 1,
      relay_ws_max_connections: 20, relay_ws_max_connections_per_peer: 2,
    },
    balanced: {
      participate_relay: true, participate_storage: true,
      owner_resource_percent: 60, relay_max_persistent_peers: 8,
      peer_guard_count: 2, peer_rotating_count: 4, peer_reserve_count: 2,
      relay_ws_max_connections: 100, relay_ws_max_connections_per_peer: 4,
    },
    transit: {
      participate_relay: true, participate_storage: true,
      owner_resource_percent: 40, relay_max_persistent_peers: 15,
      peer_guard_count: 2, peer_rotating_count: 8, peer_reserve_count: 3,
      relay_ws_max_connections: 500, relay_ws_max_connections_per_peer: 8,
    },
  };
  let applyingUsageProfile = false;

  function applyUsageProfile(profileName) {
    const profile = usageProfiles[profileName];
    if (!profile) return;
    applyingUsageProfile = true;
    Object.entries(profile).forEach(([name, value]) => {
      const field = form.elements[name];
      if (!field) return;
      if (field.type === "checkbox") field.checked = value;
      else field.value = String(value);
    });
    applyingUsageProfile = false;
  }

  function detectUsageProfile(config) {
    const comparable = (profile) => Object.entries(profile).every(([name, value]) => (
      typeof value === "boolean" ? !!config[name] === value : Number(config[name]) === value
    ));
    return Object.entries(usageProfiles).find(([, profile]) => comparable(profile))?.[0] || "custom";
  }

  function parseUrlParts(url) {
    if (!url) return { host: "localhost", port: null };
    try {
      const u = new URL(url);
      return { host: u.hostname, port: u.port || null };
    } catch (_) {
      return { host: "localhost", port: null };
    }
  }

  function defaultPortForField(name) {
    const map = { home_node_public_url: 8001, storage_node_url: 8002, media_node_public_url: 8004, relay_node_public_url: 8005 };
    return map[name] || 8001;
  }

  function resolvePublicHost() {
    const mode = form.elements.access_mode?.value || "local";
    const lan = form.elements.lan_ip?.value?.trim();
    if (mode === "local") return "localhost";
    if (mode === "lan") return lan || form.elements.public_host?.value?.trim() || "localhost";
    return form.elements.public_host?.value?.trim() || "localhost";
  }

  function buildUrl(host, port) {
    const p = Number(port) || 8001;
    const h = host || "localhost";
    return `http://${h.includes(":") ? `[${h}]` : h}:${p}`;
  }

  function syncHiddenUrls() {
    const host = resolvePublicHost();
    const home = buildUrl(host, form.elements.port_home?.value);
    form.elements.home_node_public_url.value = home;
    form.elements.storage_node_url.value = "http://storage-node:8002";
    const mediaOn = !!form.elements.enable_media?.checked;
    const relayOn = !!form.elements.enable_relay?.checked;
    form.elements.media_node_public_url.value = mediaOn
      ? buildUrl(host, form.elements.port_media?.value)
      : "http://media-node:8004";
    form.elements.relay_node_public_url.value = "http://relay-node:8005";

    const preview = document.getElementById("urlPreview");
    if (preview) {
      const lines = [`Home → ${home}`];
      if (mediaOn) lines.push(`Media → ${form.elements.media_node_public_url.value}`);
      lines.push("Storage / Relay → внутренние (Docker)");
      preview.textContent = lines.join(" · ");
    }

    document.getElementById("checkMediaBtn")?.classList.toggle("hidden", !mediaOn);
    form.querySelector(".optional-port")?.classList.toggle("hidden", !mediaOn);
    const mediaPort = form.querySelector(".optional-port input");
    if (mediaPort) mediaPort.disabled = !mediaOn;
  }

  function updateAccessModeUi() {
    const mode = form.elements.access_mode?.value || "local";
    const wrap = document.getElementById("publicHostWrap");
    const hint = document.getElementById("publicHostHint");
    if (mode === "local") {
      wrap?.classList.add("hidden");
      if (form.elements.public_host) form.elements.public_host.value = "localhost";
    } else {
      wrap?.classList.remove("hidden");
      if (mode === "lan" && form.elements.lan_ip?.value) {
        form.elements.public_host.value = form.elements.lan_ip.value.trim();
      }
      if (hint) {
        hint.textContent = mode === "lan"
          ? "IP этой машины в Wi‑Fi — телефоны подключатся по нему"
          : "Домен или IP, который видят клиенты из интернета";
      }
    }
    syncHiddenUrls();
  }

  function collectNode() {
    syncHiddenUrls();
    const node = {};
    textFields.forEach((f) => {
      const el = form.elements[f];
      if (form.elements[f]?.type === "number") {
        node[f] = Number(el.value);
      } else {
        node[f] = el.value;
      }
    });
    ["home_node_public_url", "storage_node_url", "media_node_public_url", "relay_node_public_url"].forEach((f) => {
      node[f] = form.elements[f]?.value || "";
    });
    boolFields.forEach((f) => {
      node[f] = !!form.elements[f]?.checked;
    });
    return node;
  }

  function applyLanIpHint() {
    const ip = form.elements.lan_ip?.value?.trim();
    if (!ip || ip === "127.0.0.1" || ip === "localhost") return;
    if (form.elements.access_mode?.value === "lan") {
      form.elements.public_host.value = ip;
    }
    const disc = form.elements.discovery_node_url;
    if (disc && (!disc.value || disc.value.includes("localhost"))) {
      disc.placeholder = `http://${ip}:8003`;
    }
    syncHiddenUrls();
  }

  function showCheckResult(key, result) {
    AdminUi.setFieldCheck(key, {
      ok: result.ok,
      message: result.ok
        ? `✓ ${AdminUi.formatCheckDetail(result)}`
        : `✗ ${result.error || "недоступен"}`,
    });
  }

  async function checkOne(kind) {
    syncHiddenUrls();
    const field = fieldMap[kind];
    if ((kind === "media" && !form.elements.enable_media?.checked)
      || (kind === "relay" && !form.elements.enable_relay?.checked)) {
      AdminUi.setFieldCheck(kind, { ok: true, message: "— сервис отключён" });
      return;
    }
    const url = form.elements[field]?.value?.trim();
    if (!url) {
      AdminUi.setFieldCheck(kind, { ok: false, message: "✗ Укажите адрес" });
      return;
    }
    AdminUi.setFieldCheck(kind, { loading: true, message: "Проверка…" });
    try {
      const result = kind === "discovery"
        ? await AdminApi.checkDiscovery(url)
        : await AdminApi.checkHealth(url, kind);
      showCheckResult(kind, result);
    } catch (e) {
      AdminUi.setFieldCheck(kind, { ok: false, message: `✗ ${e.message}` });
    }
  }

  async function checkAll() {
    syncHiddenUrls();
    Object.keys(fieldMap).forEach((k) => {
      if ((k === "media" && !form.elements.enable_media?.checked)
        || (k === "relay" && !form.elements.enable_relay?.checked)) {
        AdminUi.setFieldCheck(k, { ok: true, message: "— отключён" });
        return;
      }
      AdminUi.setFieldCheck(k, { loading: true, message: "Проверка…" });
    });
    AdminApi.showStatus(status, "Проверяем…");
    try {
      const payload = {
        discovery_node_url: form.elements.discovery_node_url.value,
        home_node_public_url: form.elements.home_node_public_url.value,
        storage_node_url: form.elements.storage_node_url.value,
        media_node_public_url: form.elements.media_node_public_url.value,
        relay_node_public_url: form.elements.relay_node_public_url.value,
        check_media: !!form.elements.enable_media?.checked,
        check_relay: !!form.elements.enable_relay?.checked,
      };
      const data = await AdminApi.checkSetup(payload);
      (data.checks || []).forEach((c) => {
        if (c.key) showCheckResult(c.key, c);
      });
      AdminApi.showStatus(status, data.summary, data.all_ok);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  }

  function fillPortsFromConfig(n) {
    const home = parseUrlParts(n.home_node_public_url);
    form.elements.port_home.value = home.port || 8001;
    form.elements.port_media.value = parseUrlParts(n.media_node_public_url).port || 8004;

    const host = home.host || "localhost";
    if (host === "localhost" || host === "127.0.0.1") {
      form.elements.access_mode.value = "local";
    } else if (host === (n.lan_ip || "").trim() || /^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\./.test(host)) {
      form.elements.access_mode.value = "lan";
      form.elements.public_host.value = host;
    } else {
      form.elements.access_mode.value = "custom";
      form.elements.public_host.value = host;
    }

    const mediaInternal = (n.media_node_public_url || "").includes("media-node");
    const relayInternal = (n.relay_node_public_url || "").includes("relay-node");
    form.elements.enable_media.checked = !mediaInternal;
    form.elements.enable_relay.checked = !relayInternal;
    updateAccessModeUi();
  }

  function updateJwtBadge(secrets) {
    const el = document.getElementById("jwtBadge");
    if (!el) return;
    if (!secrets?.jwt_secret_set) {
      el.textContent = "JWT — не задан";
      el.className = "security-badge warn";
    } else if (secrets.jwt_is_dev_default) {
      el.textContent = "JWT — dev-значение (смените в .env для продакшена)";
      el.className = "security-badge warn";
    } else {
      el.textContent = "JWT — настроен";
      el.className = "security-badge ok";
    }
  }

  function renderRoleReality(config, results) {
    const container = document.getElementById("roleReality");
    if (!container) return;
    const rows = [
      ["Relay", !!config.participate_relay, results.relay],
      ["Storage", !!config.participate_storage, results.storage],
    ];
    container.innerHTML = rows.map(([label, wanted, result]) => {
      const runtime = result?.runtime || {};
      const caps = Array.isArray(runtime.capabilities) ? runtime.capabilities : [];
      const advertised = caps.includes(label.toLowerCase());
      const reachable = !!result?.ok;
      const state = !wanted
        ? (label === "Storage" ? "только локальный mailbox" : "транзит отключён")
        : !reachable
          ? "сервис недоступен"
          : advertised
            ? "готов к регистрации; право проверяет Discovery"
            : "не публикуется в сети";
      const cls = wanted && (!reachable || !advertised) ? "warn" : "ok";
      return `<div class="role-reality-row ${cls}"><b>${label}</b><span>${AdminUi.escapeHtml(state)}</span></div>`;
    }).join("");
  }

  async function loadRoleReality(config) {
    const [relay, storage] = await Promise.all([
      AdminApi.checkHealth(config.relay_node_public_url, "relay").catch(() => null),
      AdminApi.checkHealth(config.storage_node_url, "storage").catch(() => null),
    ]);
    renderRoleReality(config, { relay, storage });
  }

  async function load() {
    try {
      const cfg = await AdminApi.getConfig();
      const n = cfg.node;
      textFields.forEach((f) => {
        if (form.elements[f]) form.elements[f].value = n[f] ?? "";
      });
      boolFields.forEach((f) => {
        if (form.elements[f]) form.elements[f].checked = !!n[f];
      });
      if (form.elements.usage_profile) form.elements.usage_profile.value = detectUsageProfile(n);
      fillPortsFromConfig(n);
      updateJwtBadge(cfg.secrets);
      loadRoleReality(n);
      applyLanIpHint();
      AdminClusters.renderDeploymentsList(
        document.getElementById("deployList"),
        n.cluster_id || "default",
      );
      setEditing(false);
    } catch (e) {
      AdminApi.showStatus(status, "Не удалось загрузить конфиг: " + e.message, false);
    }
  }

  form.elements.access_mode?.addEventListener("change", updateAccessModeUi);
  form.elements.usage_profile?.addEventListener("change", (event) => {
    applyUsageProfile(event.target.value);
  });
  [...textFields, ...boolFields].forEach((name) => {
    form.elements[name]?.addEventListener("change", () => {
      if (!applyingUsageProfile && form.elements.usage_profile) {
        form.elements.usage_profile.value = "custom";
      }
    });
  });
  form.elements.lan_ip?.addEventListener("blur", applyLanIpHint);
  ["port_home", "port_media", "public_host"].forEach((name) => {
    form.elements[name]?.addEventListener("input", syncHiddenUrls);
  });
  form.elements.enable_media?.addEventListener("change", syncHiddenUrls);
  form.elements.enable_relay?.addEventListener("change", syncHiddenUrls);

  document.querySelectorAll(".btn-check").forEach((btn) => {
    btn.addEventListener("click", () => checkOne(btn.dataset.check));
  });
  document.getElementById("checkAllBtn")?.addEventListener("click", checkAll);

  document.getElementById("applyConfigBtn")?.addEventListener("click", async () => {
    try {
      AdminApi.showStatus(status, "Сохраняем настройки…");
      await AdminApi.saveNode(collectNode());
      AdminApi.showStatus(status, "Настройки сохранены · обновляем сервисы ноды…");
      await AdminApi.applyConfig([
        "home-node", "storage-node", "media-node",
        "relay-node", "turn-node", "gateway-node",
      ]);
      AdminApi.showStatus(status, "Применено · сервисы получили новую конфигурацию", true);
      setEditing(false);
      AdminServices.refreshContainer(document.getElementById("servicesGrid"), svcOpts);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try {
      const res = await AdminApi.saveNode(collectNode());
      AdminApi.showStatus(status, res.message || "Сохранено: " + res.path);
      setEditing(false);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  editBtn?.addEventListener("click", () => setEditing(true));
  cancelBtn?.addEventListener("click", async () => {
    await load();
    AdminApi.showStatus(status, "Изменения отменены");
  });

  AdminToolbar.init(load);
  AdminServices.refreshContainer(document.getElementById("servicesGrid"), svcOpts);
  document.getElementById("refreshServicesBtn")?.addEventListener("click", () => {
    AdminServices.refreshContainer(document.getElementById("servicesGrid"), svcOpts);
  });
  setEditing(false);
  load();
})();
