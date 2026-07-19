(function () {
  const STEPS = ["welcome", "profile", "network", "overview"];
  let currentStep = 0;
  let setupState = null;
  let stepsDone = new Set();

  function $(id) { return document.getElementById(id); }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function updateProgress() {
    const bar = $("wizardProgress");
    if (!bar) return;
    bar.innerHTML = STEPS.map((_, i) => {
      let cls = "";
      if (i < currentStep) cls = "done";
      else if (i === currentStep) cls = "active";
      return `<span class="${cls}"></span>`;
    }).join("");
  }

  function showStep(idx) {
    currentStep = Math.max(0, Math.min(idx, STEPS.length - 1));
    STEPS.forEach((name, i) => {
      const el = $(`step-${name}`);
      if (el) el.hidden = i !== currentStep;
    });
    updateProgress();
  }

  function updateOwnerWizardUi(pct) {
    const owner = Math.max(20, Math.min(100, Number(pct) || 40));
    const label = $("wizardOwnerLabel");
    if (label) label.textContent = `${owner}% для вас · ${100 - owner}% для сети`;
    const slider = $("wizardOwnerPct");
    if (slider) slider.value = String(owner);
  }

  function applySetupState(data) {
    setupState = data;
    stepsDone = new Set(data.setup_steps_done || []);
    if (data.owner_display_name && $("profileName")) {
      $("profileName").value = data.owner_display_name;
    }
    if (data.panel_admin_login && $("profileLogin")) {
      $("profileLogin").value = data.panel_admin_login;
    }
    updateOwnerWizardUi(data.owner_resource_percent ?? 40);
    const part = data.participation || {};
    const relay = $("wizRelay");
    const storage = $("wizStorage");
    if (relay) relay.checked = part.relay !== false;
    if (storage) storage.checked = part.storage !== false;
    refreshChecklistUi();
  }

  function refreshChecklistUi() {
    ["connect", "discover", "benchmark", "recommend"].forEach((step) => {
      const item = $(`check-${step}`);
      if (!item) return;
      item.classList.toggle("done", stepsDone.has(step));
      const badge = item.querySelector(".check-badge");
      if (badge) badge.textContent = stepsDone.has(step) ? "✓" : "—";
    });
  }

  function setCheckResult(step, html, ok) {
    const el = $(`result-${step}`);
    if (!el) return;
    el.innerHTML = html;
    el.className = `check-result ${ok ? "ok" : "err"}`;
  }

  async function fetchStatus() {
    const res = await fetch("/monitor/setup/status");
    if (!res.ok) throw new Error("Не удалось загрузить настройку");
    return res.json();
  }

  async function saveProfile() {
    const relay = $("wizRelay");
    const storage = $("wizStorage");
    const body = {
      owner_display_name: ($("profileName")?.value || "").trim(),
      panel_admin_login: ($("profileLogin")?.value || "").trim(),
      panel_admin_password: ($("profilePassword")?.value || "").trim() || undefined,
      owner_resource_percent: Number($("wizardOwnerPct")?.value) || 40,
      participation: {
        relay: !!relay?.checked,
        storage: !!storage?.checked,
        witness: false,
        media_cache: false,
        nat_assist: false,
      },
    };
    const res = await fetch("/monitor/setup/profile", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function runAction(step, url) {
    const btn = $(`btn-${step}`);
    if (btn) { btn.disabled = true; btn.textContent = "…"; }
    try {
      const res = await fetch(url, { method: "POST" });
      const data = await res.json();
      if (data.setup_steps_done) {
        stepsDone = new Set(data.setup_steps_done);
        refreshChecklistUi();
      } else if (data.step) {
        stepsDone.add(data.step);
        refreshChecklistUi();
      }
      renderActionResult(step, data);
      return data;
    } catch (e) {
      setCheckResult(step, escapeHtml(e.message), false);
      return null;
    } finally {
      if (btn) { btn.disabled = false; btn.textContent = btn.dataset.label || "Проверить"; }
    }
  }

  function renderActionResult(step, data) {
    if (!data) return;
    const ok = !!data.ok;
    let html = escapeHtml(data.message || (ok ? "Готово" : "Ошибка"));
    if (step === "connect" && data.latency_ms != null) {
      html += ` · ${data.latency_ms} ms`;
    }
    if (step === "discover" && data.peers?.length) {
      html += `<ul>${data.peers.slice(0, 6).map((p) =>
        `<li>${escapeHtml(p.display_name)} · ${escapeHtml(p.status_label)}</li>`).join("")}</ul>`;
    }
    if (step === "benchmark" && data.ranked?.length) {
      html += `<ul>${data.ranked.slice(0, 5).map((p) =>
        `<li>${escapeHtml(p.display_name)} · ${p.latency_ms} ms</li>`).join("")}</ul>`;
    }
    if (step === "recommend" && data.recommendations?.length) {
      html += `<ul>${data.recommendations.map((p) =>
        `<li>${escapeHtml(p.display_name)} — ${escapeHtml(p.reason)}</li>`).join("")}</ul>`;
    }
    setCheckResult(step, html, ok);
  }

  function finishWizard() {
    const overlay = $("wizardOverlay");
    const dash = $("mainDashboard");
    if (overlay) {
      overlay.classList.add("hidden");
      overlay.style.display = "none";
      overlay.setAttribute("hidden", "");
    }
    if (dash) {
      dash.classList.remove("dashboard-hidden");
      dash.style.visibility = "visible";
      dash.style.height = "auto";
      dash.style.overflow = "visible";
    }
    if (window.OwnerPanel?.onWizardComplete) window.OwnerPanel.onWizardComplete(setupState);
  }

  async function completeSetup() {
    await fetch("/monitor/setup/complete", { method: "POST" });
    finishWizard();
  }

  async function skipSetup() {
    const buttons = document.querySelectorAll(".wizard-skip");
    buttons.forEach((btn) => { btn.disabled = true; });
    try {
      const data = await fetch("/monitor/setup/skip", { method: "POST" }).then((r) => r.json());
      applySetupState(data);
      ["connect", "discover", "benchmark", "recommend"].forEach((s) => {
        const r = (data.results || []).find((x) => x.step === s);
        if (r) renderActionResult(s, r);
      });
      finishWizard();
    } catch (e) {
      alert(e.message);
    } finally {
      buttons.forEach((btn) => { btn.disabled = false; });
    }
  }

  function bindEvents() {
    document.querySelectorAll(".wizard-back").forEach((btn) => {
      btn.addEventListener("click", () => showStep(currentStep - 1));
    });
    document.querySelectorAll(".wizard-skip").forEach((btn) => {
      btn.addEventListener("click", skipSetup);
    });

    $("wizardToProfile")?.addEventListener("click", () => showStep(1));

    $("wizardSaveProfile")?.addEventListener("click", async () => {
      try {
        const data = await saveProfile();
        applySetupState(data);
        showStep(2);
      } catch (e) {
        alert(e.message);
      }
    });

    $("wizardToOverview")?.addEventListener("click", async () => {
      try {
        const data = await saveProfile();
        applySetupState(data);
        showStep(3);
      } catch (e) {
        alert(e.message);
      }
    });

    $("wizardOwnerPct")?.addEventListener("input", (e) => updateOwnerWizardUi(e.target.value));

    $("btn-connect")?.addEventListener("click", () => runAction("connect", "/monitor/setup/connect"));
    $("btn-discover")?.addEventListener("click", () => runAction("discover", "/monitor/setup/discover"));
    $("btn-benchmark")?.addEventListener("click", () => runAction("benchmark", "/monitor/setup/benchmark"));
    $("btn-recommend")?.addEventListener("click", () => runAction("recommend", "/monitor/setup/recommend"));

    $("wizardFinish")?.addEventListener("click", completeSetup);
    $("wizardSkip")?.addEventListener("click", skipSetup);
  }

  async function init() {
    bindEvents();
    try {
      const data = await fetchStatus();
      applySetupState(data);
      if (data.setup_completed) {
        finishWizard();
        return;
      }
      showStep(0);
    } catch (_) {
      showStep(0);
    }
  }

  window.OwnerWizard = { init, finishWizard };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
