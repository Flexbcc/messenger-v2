// Значения read_only-настроек заполняются системой (не пользователем).
// В прототипе — демонстрационные данные. В бою приходят с клиента/сервера.
// Эти значения НЕ входят в редактируемое/валидируемое/экспортируемое состояние.

export const SYSTEM_VALUES = {
  "profile.public_id": "OUO-8F2A-19C4-77DB",
  "identity.phone_verified": false,
  "identity.email_verified": false,
  "security.pin_attempt_policy": "5 попыток, затем задержка 30с",
  "devices.current": "Pixel 8 (этот телефон)",
  "node.current": "node-eu-west-3.ouo.local",
  "node.certificate_fingerprint": "SHA256:9d:af:2c:71:… :e0",
  "storage.summary": "Сообщения — на устройстве; медиа — личная нода (S3); ключи — Secure Enclave",
  "storage.last_sync": "2026-07-13 15:42 (7 минут назад)",
  "storage.last_backup": "2026-07-06 03:10 (7 дней назад)",
  "developer.protocol_version": "OUO/1.0.0"
};

// Дополнительные системные факты для раздела «Хранение и владение данными»
// (требование 13) — то, что нельзя вывести только из пользовательских значений.
export const STORAGE_FACTS = {
  physical_locations: [
    { label: "Сообщения", place: "Локальное устройство", detail: "зашифрованная БД" },
    { label: "Медиа", place: "Личная нода (S3)", detail: "eu-west-3, зашифровано" },
    { label: "Ключи", place: "Secure Enclave устройства", detail: "не покидают устройство" }
  ],
  encrypted_copies: true,
  replicas: 2,
  ttl: "медиа — 30 дней, сообщения — бессрочно",
  last_sync: "2026-07-13 15:42",
  last_backup: "2026-07-06 03:10",
  devices_with_keys: [
    { id: "dev_current", name: "Pixel 8 (этот телефон)", platform: "android", has_keys: true },
    { id: "dev_laptop", name: "MacBook Pro", platform: "desktop", has_keys: true }
  ],
  storage_nodes: [
    { id: "node_eu3", address: "node-eu-west-3.ouo.local", region: "EU", encrypted_only: true },
    { id: "node_eu1", address: "node-eu-north-1.ouo.local", region: "EU", encrypted_only: true }
  ]
};
