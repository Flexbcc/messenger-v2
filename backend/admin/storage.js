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

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    try {
      const res = await AdminApi.saveStorage(collectStorage());
      AdminApi.showStatus(status, "Сохранено: " + res.path);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  document.getElementById("reloadMediaBtn").addEventListener("click", async () => {
    try {
      await AdminApi.saveStorage(collectStorage());
      const res = await AdminApi.reloadMedia();
      AdminApi.showStatus(status, res.message || "Конфиг применён на media-node");
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  document.getElementById("backupNowBtn").addEventListener("click", async () => {
    try {
      await AdminApi.saveStorage(collectStorage());
      const res = await AdminApi.runBackup();
      AdminApi.showStatus(status, `Бэкап: ${res.files ?? 0} файлов → ${res.destination}`);
    } catch (e) {
      AdminApi.showStatus(status, e.message, false);
    }
  });

  load();
})();
