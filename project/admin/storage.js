(function () {
  const form = document.getElementById("storageForm");
  const status = document.getElementById("status");
  const mediaPrimary = document.getElementById("mediaPrimaryBackend");
  const backupBackend = document.getElementById("backupBackend");
  const mediaS3Block = document.getElementById("mediaS3Block");
  const backupS3Block = document.getElementById("backupS3Block");

  function toggleS3() {
    mediaS3Block.classList.toggle("hidden", mediaPrimary.value !== "s3");
    backupS3Block.classList.toggle("hidden", backupBackend.value !== "s3");
  }
  mediaPrimary.addEventListener("change", toggleS3);
  backupBackend.addEventListener("change", toggleS3);

  function fillForm(storage) {
    const m = storage.media;
    const p = storage.personal_cloud;
    const b = storage.backup;
    form.media_primary_backend.value = m.primary_backend;
    form.media_local_path.value = m.local_path;
    form.network_cache_ttl_hours.value = m.network_cache_ttl_hours;
    form.media_s3_endpoint.value = m.s3.endpoint_url;
    form.media_s3_bucket.value = m.s3.bucket;
    form.media_s3_access_key.value = m.s3.access_key;
    form.media_s3_secret_key.value = m.s3.secret_key;
    form.media_s3_region.value = m.s3.region;
    form.media_s3_prefix.value = m.s3.prefix;
    form.personal_cloud_enabled.checked = p.enabled;
    form.default_for_node_users.value = p.default_for_node_users;
    form.backup_enabled.checked = b.enabled;
    form.backup_backend.value = b.backend;
    form.backup_local_path.value = b.local_path;
    form.backup_schedule_hours.value = b.schedule_hours;
    form.backup_s3_endpoint.value = b.s3.endpoint_url;
    form.backup_s3_bucket.value = b.s3.bucket;
    form.backup_s3_access_key.value = b.s3.access_key;
    form.backup_s3_secret_key.value = b.s3.secret_key;
    form.backup_s3_prefix.value = b.s3.prefix;
    toggleS3();
  }

  function collectStorage() {
    return {
      media: {
        primary_backend: form.media_primary_backend.value,
        local_path: form.media_local_path.value,
        network_cache_ttl_hours: Number(form.network_cache_ttl_hours.value),
        s3: {
          enabled: form.media_primary_backend.value === "s3",
          endpoint_url: form.media_s3_endpoint.value,
          bucket: form.media_s3_bucket.value,
          access_key: form.media_s3_access_key.value,
          secret_key: form.media_s3_secret_key.value,
          region: form.media_s3_region.value,
          prefix: form.media_s3_prefix.value,
        },
      },
      personal_cloud: {
        enabled: form.personal_cloud_enabled.checked,
        default_for_node_users: form.default_for_node_users.value,
        allow_user_personal_s3: true,
        users: {},
      },
      backup: {
        enabled: form.backup_enabled.checked,
        backend: form.backup_backend.value,
        local_path: form.backup_local_path.value,
        schedule_hours: Number(form.backup_schedule_hours.value),
        include_media: true,
        include_home_db: true,
        s3: {
          enabled: form.backup_backend.value === "s3",
          endpoint_url: form.backup_s3_endpoint.value,
          bucket: form.backup_s3_bucket.value,
          access_key: form.backup_s3_access_key.value,
          secret_key: form.backup_s3_secret_key.value,
          region: "us-east-1",
          prefix: form.backup_s3_prefix.value,
        },
      },
    };
  }

  async function load() {
    try {
      const cfg = await AdminApi.getConfig();
      fillForm(cfg.storage);
    } catch (e) {
      AdminApi.showStatus(status, "Ошибка загрузки: " + e.message, false);
    }
  }

  async function checkMedia() {
    AdminUi.setFieldCheck("media", { loading: true, message: "Проверка…" });
    try {
      const cfg = await AdminApi.getConfig();
      const url = cfg.node?.media_node_public_url || "";
      const result = await AdminApi.checkMedia(url);
      AdminUi.setFieldCheck("media", {
        ok: result.ok,
        message: result.ok
          ? `✓ Media-node доступен · ${AdminUi.formatCheckDetail(result)}`
          : `✗ ${result.error || "недоступен"}`,
      });
    } catch (e) {
      AdminUi.setFieldCheck("media", { ok: false, message: `✗ ${e.message}` });
    }
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try {
      const res = await AdminApi.saveStorage(collectStorage());
      AdminApi.showStatus(status, "Сохранено на диск: " + res.path + " · для применения нажмите «Применить без перезапуска»");
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  document.getElementById("checkMediaBtn").addEventListener("click", checkMedia);

  document.getElementById("reloadMediaBtn").addEventListener("click", async () => {
    try {
      await AdminApi.saveStorage(collectStorage());
      const res = await AdminApi.reloadMedia();
      AdminApi.showStatus(status, res.message || "Конфиг перечитан media-node (без перезапуска)");
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  document.getElementById("backupNowBtn").addEventListener("click", async () => {
    if (!form.backup_enabled.checked) {
      AdminApi.showStatus(status, "Включите бэкап в настройках выше", false);
      return;
    }
    try {
      await AdminApi.saveStorage(collectStorage());
      const res = await AdminApi.runBackup();
      if (res.status === "skipped") {
        AdminApi.showStatus(status, "Бэкап пропущен: " + (res.reason || "отключён"), false);
        return;
      }
      AdminApi.showStatus(status, `Бэкап готов: ${res.files ?? 0} файлов → ${res.destination || "—"}`);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  AdminToolbar.init(load);
  load();
})();
