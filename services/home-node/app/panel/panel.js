(function () {
  const REFRESH_MS = 5000;
  let refreshTimer = null;
  let ownerDisplayName = "";
  const STATUS_CLASS = {
    normal: "status-normal",
    busy: "status-busy",
    overloaded: "status-overloaded",
    critical: "status-critical",
    online: "status-online",
    offline: "status-offline",
  };

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function formatBytes(bytes) {
    if (!bytes) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let v = bytes;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  }

  function formatUptime(sec) {
    if (sec == null) return "—";
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 48) return `${Math.floor(h / 24)} д`;
    if (h > 0) return `${h} ч ${m} м`;
    return `${m} м`;
  }

  function setHealthRing(score) {
    const arc = document.getElementById("healthArc");
    const label = document.getElementById("healthScore");
    if (score == null) {
      label.textContent = "—";
      return;
    }
    label.textContent = String(score);
    const c = 2 * Math.PI * 52;
    arc.style.strokeDasharray = `${c}`;
    arc.style.strokeDashoffset = String(c * (1 - score / 100));
    arc.classList.toggle("health-low", score < 60);
    arc.classList.toggle("health-mid", score >= 60 && score < 85);
  }

  function updateOwnerUi(pct) {
    const owner = Math.max(20, Math.min(100, Number(pct) || 40));
    document.getElementById("ownerPctLabel").textContent = `${owner}% / ${100 - owner}%`;
    document.getElementById("barOwner").style.width = `${owner}%`;
    document.getElementById("barNet").style.width = `${100 - owner}%`;
    document.getElementById("ownerPct").value = String(owner);
  }

  function renderSnapshot(snap) {
    const status = snap.runtime_status || "normal";
    const pill = document.getElementById("runtimeStatusPill");
    pill.textContent = snap.runtime_status_label || status;
    pill.className = `status-pill ${STATUS_CLASS[status] || ""}`;
    document.getElementById("localNodeTitle").textContent =
      ownerDisplayName ? `Home Node · ${ownerDisplayName}` : "Моя Home Node";
    const net = snap.network || {};
    document.getElementById("localNodeMeta").textContent =
      `v${net.software_version || "?"} · ${net.resource_policy || "—"} · без публикации адресов сети`;

    setHealthRing(snap.health_score);
    const m = snap.metrics || {};
    document.getElementById("mCpu").textContent =
      m.cpu_percent_est != null ? `${m.cpu_percent_est}%` : "—";
    document.getElementById("mRam").textContent = m.ram_total_bytes
      ? `${formatBytes(m.ram_used_bytes)} / ${formatBytes(m.ram_total_bytes)}${m.ram_percent != null ? ` (${m.ram_percent}%)` : ""}`
      : "—";
    document.getElementById("mDisk").textContent = m.disk_total_bytes
      ? `${formatBytes(m.disk_used_bytes)} / ${formatBytes(m.disk_total_bytes)}${m.disk_percent != null ? ` (${m.disk_percent}%)` : ""}`
      : "—";
    document.getElementById("mConn").textContent =
      `${m.online_users ?? 0} · ${m.active_ws_connections ?? 0} WS`;
    document.getElementById("mSync").textContent = String(m.sync_queue ?? 0);
    document.getElementById("mUptime").textContent = formatUptime(m.uptime_sec);

    const part = net.participation || {};
    const form = document.getElementById("prefsForm");
    ["relay", "storage", "witness", "media_cache", "nat_assist"].forEach((k) => {
      if (form.elements[k]) form.elements[k].checked = !!part[k];
    });
    updateOwnerUi(net.owner_resource_percent ?? 40);

    const conns = snap.connections || [];
    document.getElementById("connCount").textContent = String(conns.length);
    const body = document.getElementById("connectionsBody");
    if (!conns.length) {
      body.innerHTML = '<tr><td colspan="4" class="empty">Нет сессий</td></tr>';
    } else {
      body.innerHTML = conns.map((c) => `
        <tr>
          <td><code>${escapeHtml(shortRef(c.user_id))}</code></td>
          <td><code>${escapeHtml(shortRef(c.device_id))}</code></td>
          <td>${escapeHtml(c.device_type || "—")}</td>
          <td>${escapeHtml(String(c.ws_connections ?? 1))}</td>
        </tr>`).join("");
    }
  }

  function shortRef(id) {
    if (!id) return "—";
    const s = String(id);
    return s.length <= 10 ? s : `${s.slice(0, 6)}…${s.slice(-4)}`;
  }

  function validatePairPayload(text) {
    let obj;
    try {
      obj = JSON.parse(text);
    } catch (_) {
      throw new Error("Некорректный JSON");
    }
    if (obj.kind !== "ouo_ppc_pair") {
      throw new Error('Нужен kind "ouo_ppc_pair"');
    }
    return JSON.stringify(obj);
  }

  function formatPairSuccess(data) {
    const parts = [];
    if (data.lan_hint) parts.push(`LAN: ${data.lan_hint}`);
    if (data.relay_url) parts.push(`relay: ${data.relay_url}`);
    if (data.storage_node_id) parts.push(`node: ${shortRef(data.storage_node_id)}`);
    return parts.length ? `OK · ${parts.join(" · ")}` : "OK · paired";
  }

  function renderPeers(data) {
    const peers = data.peers || [];
    const summary = data.summary || {};
    document.getElementById("peerSummary").textContent =
      `${summary.online ?? 0} онлайн · ${summary.total ?? 0} в сети`;

    const chips = document.getElementById("peerChips");
    chips.innerHTML = peers.map((p) => {
      const cls = [
        "peer-chip",
        p.online ? "online" : "offline",
        p.status === "busy" || p.status === "overloaded" ? "busy" : "",
        p.is_self ? "self" : "",
      ].filter(Boolean).join(" ");
      return `<span class="${cls}"><span class="dot"></span>${escapeHtml(p.display_name)} · ${escapeHtml(p.status_label)}</span>`;
    }).join("") || '<span class="muted">Сеть пока пуста</span>';

    renderMap(peers);
  }

  function renderMap(peers) {
    const svg = document.getElementById("networkSvg");
    const w = 800;
    const h = 300;
    const cx = w / 2;
    const cy = h / 2 + 20;
    const others = peers.filter((p) => !p.is_self).slice(0, 10);
    const self = peers.find((p) => p.is_self);
    const radius = 110;
    let out = `<rect width="${w}" height="${h}" fill="transparent"/>`;
    out += `<text x="${cx}" y="28" class="map-label">Сеть (роли)</text>`;

    others.forEach((p, i) => {
      const angle = (Math.PI * 2 * i) / Math.max(others.length, 1) - Math.PI / 2;
      const px = cx + Math.cos(angle) * radius;
      const py = cy + Math.sin(angle) * (radius * 0.55);
      out += `<line x1="${cx}" y1="${cy}" x2="${px}" y2="${py}" class="map-line ${p.online ? "" : "map-line-dim"}"/>`;
      out += `<circle cx="${px}" cy="${py}" r="26" class="map-node ${p.online ? "map-online" : "map-offline"}"/>`;
      out += `<text x="${px}" y="${py + 4}" class="map-label-sm">${escapeHtml(p.role_label)}</text>`;
    });

    const st = self?.status || "normal";
    out += `<circle cx="${cx}" cy="${cy}" r="34" class="map-node map-home map-${self?.online ? "online" : "offline"}"/>`;
    out += `<text x="${cx}" y="${cy - 4}" class="map-label">Home</text>`;
    out += `<text x="${cx}" y="${cy + 14}" class="map-label-sm">${escapeHtml(self?.status_label || st)}</text>`;
    svg.innerHTML = out;
  }

  async function refresh() {
    try {
      const snap = await fetch("/monitor/snapshot").then((r) => r.json());
      renderSnapshot(snap);
    } catch (_) { /* ignore */ }

    try {
      const peers = await fetch("/monitor/network/peers").then((r) => r.json());
      renderPeers(peers);
    } catch (err) {
      document.getElementById("peerChips").innerHTML =
        `<span class="muted">Сеть недоступна</span>`;
    }
  }

  const ownerPct = document.getElementById("ownerPct");
  ownerPct.addEventListener("input", () => updateOwnerUi(ownerPct.value));

  document.getElementById("prefsForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const form = ev.target;
    const status = document.getElementById("prefsStatus");
    try {
      const res = await fetch("/monitor/prefs", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          owner_resource_percent: Number(ownerPct.value) || 40,
          participation: {
            relay: !!form.elements.relay.checked,
            storage: !!form.elements.storage.checked,
            witness: !!form.elements.witness.checked,
            media_cache: !!form.elements.media_cache.checked,
            nat_assist: !!form.elements.nat_assist.checked,
          },
        }),
      });
      if (!res.ok) throw new Error(await res.text());
      status.textContent = "Сохранено";
      status.className = "status-msg ok";
      refresh();
    } catch (e) {
      status.textContent = e.message;
      status.className = "status-msg err";
    }
  });

  document.getElementById("themeToggle").addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme");
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    const isDark = cur === "dark" || (!cur && prefersDark);
    const next = isDark ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("owner_panel_theme", next);
  });
  const saved = localStorage.getItem("owner_panel_theme");
  if (saved) document.documentElement.setAttribute("data-theme", saved);

  document.getElementById("refreshBtn").addEventListener("click", refresh);

  const qrOverlay = document.getElementById("qrScannerOverlay");
  const qrViewport = document.getElementById("qrScannerViewport");
  const qrVideo = document.getElementById("qrScannerVideo");
  const qrStatus = document.getElementById("qrScannerStatus");
  let qrStream = null;
  let qrDetectRaf = null;
  let qrHtml5Instance = null;
  let qrScanHandled = false;

  async function loadHtml5QrcodeLib() {
    if (window.Html5Qrcode) return window.Html5Qrcode;
    await new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js";
      s.onload = resolve;
      s.onerror = () => reject(new Error("Не удалось загрузить QR-библиотеку"));
      document.head.appendChild(s);
    });
    return window.Html5Qrcode;
  }

  function stopQrStream() {
    if (qrDetectRaf) {
      cancelAnimationFrame(qrDetectRaf);
      qrDetectRaf = null;
    }
    if (qrStream) {
      qrStream.getTracks().forEach((t) => t.stop());
      qrStream = null;
    }
    if (qrVideo) {
      qrVideo.srcObject = null;
      qrVideo.hidden = true;
    }
  }

  async function stopHtml5Qr() {
    if (qrHtml5Instance) {
      try { await qrHtml5Instance.stop(); } catch (_) { /* ignore */ }
      try { qrHtml5Instance.clear(); } catch (_) { /* ignore */ }
      qrHtml5Instance = null;
    }
    if (qrViewport) qrViewport.innerHTML = "";
  }

  async function closeQrScanner() {
    stopQrStream();
    await stopHtml5Qr();
    qrScanHandled = false;
    if (qrStatus) {
      qrStatus.textContent = "";
      qrStatus.className = "status-msg";
    }
    if (qrOverlay) qrOverlay.hidden = true;
  }

  function handleQrResult(raw) {
    if (qrScanHandled) return;
    const text = String(raw || "").trim();
    if (!text) return;
    const storagePairForm = document.getElementById("storagePairForm");
    const pairStatus = document.getElementById("storagePairStatus");
    try {
      const normalized = validatePairPayload(text);
      qrScanHandled = true;
      if (storagePairForm?.elements.payload) {
        storagePairForm.elements.payload.value = normalized;
      }
      closeQrScanner();
      if (pairStatus) {
        pairStatus.textContent = "QR отсканирован";
        pairStatus.className = "status-msg ok";
        setTimeout(() => {
          if (pairStatus.textContent === "QR отсканирован") {
            pairStatus.textContent = "";
            pairStatus.className = "status-msg";
          }
        }, 3000);
      }
    } catch (e) {
      if (qrStatus) {
        qrStatus.textContent = e.message;
        qrStatus.className = "status-msg err";
      }
    }
  }

  async function startBarcodeDetectorScan() {
    const detector = new BarcodeDetector({ formats: ["qr_code"] });
    qrStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment" },
      audio: false,
    });
    qrVideo.srcObject = qrStream;
    qrVideo.hidden = false;
    if (qrViewport) qrViewport.hidden = true;
    await qrVideo.play();

    const tick = async () => {
      if (qrOverlay?.hidden || qrScanHandled) return;
      try {
        const codes = await detector.detect(qrVideo);
        if (codes.length) {
          handleQrResult(codes[0].rawValue);
          return;
        }
      } catch (_) { /* ignore frame errors */ }
      qrDetectRaf = requestAnimationFrame(tick);
    };
    qrDetectRaf = requestAnimationFrame(tick);
  }

  async function startHtml5QrcodeScan() {
    const Html5Qrcode = await loadHtml5QrcodeLib();
    if (qrVideo) qrVideo.hidden = true;
    if (qrViewport) {
      qrViewport.hidden = false;
      qrViewport.innerHTML = '<div id="qrHtml5Reader" style="width:100%"></div>';
    }
    qrHtml5Instance = new Html5Qrcode("qrHtml5Reader");
    await qrHtml5Instance.start(
      { facingMode: "environment" },
      { fps: 10, qrbox: { width: 250, height: 250 } },
      (decoded) => handleQrResult(decoded),
      () => {}
    );
  }

  async function openQrScanner() {
    if (!qrOverlay) return;
    qrScanHandled = false;
    if (qrStatus) {
      qrStatus.textContent = "Запрос доступа к камере…";
      qrStatus.className = "status-msg";
    }
    qrOverlay.hidden = false;

    try {
      if ("BarcodeDetector" in window) {
        await startBarcodeDetectorScan();
      } else {
        await startHtml5QrcodeScan();
      }
      if (qrStatus) qrStatus.textContent = "";
    } catch (e) {
      if (qrStatus) {
        qrStatus.textContent = e.message || "Камера недоступна";
        qrStatus.className = "status-msg err";
      }
    }
  }

  const storageQrScanBtn = document.getElementById("storageQrScanBtn");
  if (storageQrScanBtn) storageQrScanBtn.addEventListener("click", openQrScanner);
  const qrScannerClose = document.getElementById("qrScannerClose");
  if (qrScannerClose) qrScannerClose.addEventListener("click", closeQrScanner);
  if (qrOverlay) {
    qrOverlay.addEventListener("click", (ev) => {
      if (ev.target === qrOverlay) closeQrScanner();
    });
  }

  const storagePairForm = document.getElementById("storagePairForm");
  if (storagePairForm) {
    storagePairForm.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      const status = document.getElementById("storagePairStatus");
      status.textContent = "…";
      status.className = "status-msg";
      const fd = new FormData(storagePairForm);
      const userId = String(fd.get("user_id") || "").trim();
      let payload = String(fd.get("payload") || "").trim();
      try {
        payload = validatePairPayload(payload);
      } catch (e) {
        status.textContent = e.message;
        status.className = "status-msg err";
        return;
      }
      try {
        const res = await fetch("/monitor/storage/personal-pc/pair", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ user_id: userId, payload }),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.detail || res.statusText);
        status.textContent = formatPairSuccess(data);
        status.className = "status-msg ok";
      } catch (e) {
        status.textContent = e.message;
        status.className = "status-msg err";
      }
    });
  }

  async function bootstrap() {
    try {
      const setup = await fetch("/monitor/setup/status").then((r) => r.json());
      ownerDisplayName = setup.owner_display_name || "";
      if (setup.setup_completed) {
        startDashboard();
      }
    } catch (_) {
      startDashboard();
    }
  }

  function startDashboard() {
    // Setup already done (API) — hide wizard and show dashboard.
    // Without this, overlay stays and prefs look "missing".
    const overlay = document.getElementById("wizardOverlay");
    const dash = document.getElementById("mainDashboard");
    if (overlay) overlay.classList.add("hidden");
    if (dash) dash.classList.remove("dashboard-hidden");
    refresh();
    if (!refreshTimer) refreshTimer = setInterval(refresh, REFRESH_MS);
  }

  window.OwnerPanel = {
    onWizardComplete(state) {
      ownerDisplayName = state?.owner_display_name || ownerDisplayName;
      startDashboard();
    },
  };

  bootstrap();
})();
