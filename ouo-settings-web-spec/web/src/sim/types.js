// OUO Network Simulation — модель данных (framework-agnostic).
// Здесь только константы и справочники. Логика симуляции — в engine.js,
// сценарии — в scenarios.js. Технические id/типы событий не переводятся.

export const OBJECT_KIND = {
  USER: "user",
  DEVICE: "device",
  NODE_PERSONAL: "personal",
  NODE_LOCAL: "local",
  NODE_PUBLIC: "public",
  BOOTSTRAP: "bootstrap",
  DISCOVERY: "discovery",
  RELAY: "relay",
  WITNESS: "witness",
  STORAGE: "storage",
  NAT: "nat",
  LAN: "lan",
  INTERNET: "internet"
};

// Сетевое положение ноды (раздел 3 ТЗ).
export const NET_MODE = {
  PUBLIC: "public",
  NAT_CONE: "nat_cone",
  NAT_RESTRICTED: "nat_restricted",
  NAT_SYMMETRIC: "nat_symmetric",
  LOCAL_ONLY: "local_only",
  OFFLINE: "offline"
};

export function isNat(mode) {
  return mode === NET_MODE.NAT_CONE || mode === NET_MODE.NAT_RESTRICTED || mode === NET_MODE.NAT_SYMMETRIC;
}

// Состояния ноды (раздел 4 ТЗ).
export const NODE_STATE = {
  CREATED: "created",
  STARTING: "starting",
  LOCAL_READY: "local_ready",
  CONTACTING_BOOTSTRAP: "contacting_bootstrap",
  VALIDATING: "validating_credentials",
  REGISTERING: "registering",
  ONLINE: "online",
  DEGRADED: "degraded",
  OFFLINE: "offline",
  BLOCKED: "blocked",
  RELAYING: "relaying",
  DELIVERING: "delivering",
  SEARCHING: "searching"
};

// Типы связей и их визуальные стили (раздел 16 ТЗ).
export const EDGE_KIND = {
  SERVICE: "service",     // синий — служебный трафик
  DIRECT: "direct",       // сплошная — активное прямое соединение
  RELAY: "relay",         // через relay
  MEDIA: "media",         // фиолетовый — encrypted media
  POTENTIAL: "potential", // пунктир — потенциальный маршрут
  DELIVERED: "delivered", // зелёный — успешная доставка
  RETRY: "retry",         // жёлтый
  ERROR: "error",         // красный
  LAN: "lan",             // связь внутри LAN
  TRUSTED: "trusted",     // локальный доверенный канал (спокойный цвет)
  BLOCKED: "blocked"      // заблокированная атака — красный пунктир
};

export const EDGE_STYLE = {
  none:      { color: "#c3c9d4", dash: "4 4", width: 1.5 },
  service:   { color: "#2f6df6", dash: "5 4", width: 2 },
  direct:    { color: "#3b3f4a", dash: null, width: 2.4 },
  relay:     { color: "#2f6df6", dash: null, width: 2.4 },
  media:     { color: "#9b59d0", dash: null, width: 2.4 },
  potential: { color: "#c3c9d4", dash: "6 5", width: 1.8 },
  delivered: { color: "#17915a", dash: null, width: 2.8 },
  retry:     { color: "#d99a00", dash: "3 3", width: 2.4 },
  error:     { color: "#e5484d", dash: "2 4", width: 2.4 },
  lan:       { color: "#17915a", dash: "5 4", width: 2 },
  trusted:   { color: "#0e9db3", dash: null, width: 2.6 },
  blocked:   { color: "#e5484d", dash: "3 5", width: 2.6 }
};

// Состояния ноды в контексте нагрузки/безопасности (разделы 10, 12, 19–20 ТЗ).
export const SEC_STATE = {
  NORMAL: "normal",
  BUSY: "busy",
  OVERLOADED: "overloaded",
  CRITICAL: "critical",
  OFFLINE: "offline",
  COMPROMISED: "compromised",
  OUTDATED: "outdated"
};

export const SEC_STATE_COLOR = {
  normal: "#17915a",
  busy: "#d99a00",
  overloaded: "#e0762b",
  critical: "#e5484d",
  offline: "#9aa1ad",
  compromised: "#b3261e",
  outdated: "#7b5bd6"
};

// Роли/возможности ноды OUO Home (раздел 8, 32 ТЗ).
export const CAPABILITY = {
  MESSAGING: "messaging",
  PERSONAL_STORAGE: "personal_storage",
  SYNC: "sync",
  RELAY: "relay",
  TEMP_STORAGE: "temporary_storage",
  DISCOVERY: "discovery",
  WITNESS: "witness",
  UPDATE: "update"
};

// Цвет статуса объекта (кольцо/заливка).
export const STATUS_COLOR = {
  online: "#17915a",
  offline: "#9aa1ad",
  degraded: "#d99a00",
  registering: "#2f6df6",
  contacting_bootstrap: "#2f6df6",
  validating_credentials: "#2f6df6",
  starting: "#2f6df6",
  created: "#9aa1ad",
  local_ready: "#17915a",
  searching: "#2f6df6",
  relaying: "#9b59d0",
  delivering: "#17915a",
  blocked: "#e5484d"
};

// Список типов событий (раздел 22 ТЗ) — используются как технические,
// НЕ переводимые идентификаторы; человекочитаемое описание идёт отдельно.
export const EVENT_TYPE = {
  USER_CREATED: "USER_CREATED",
  DEVICE_CREATED: "DEVICE_CREATED",
  NODE_CREATED: "NODE_CREATED",
  NODE_STARTED: "NODE_STARTED",
  BOOTSTRAP_REQUEST: "BOOTSTRAP_REQUEST",
  BOOTSTRAP_RESPONSE: "BOOTSTRAP_RESPONSE",
  NODE_REGISTER_REQUEST: "NODE_REGISTER_REQUEST",
  NODE_REGISTERED: "NODE_REGISTERED",
  HEARTBEAT_SENT: "HEARTBEAT_SENT",
  ROUTE_RECORD_PUBLISHED: "ROUTE_RECORD_PUBLISHED",
  ROUTE_LOOKUP_STARTED: "ROUTE_LOOKUP_STARTED",
  ROUTE_FOUND: "ROUTE_FOUND",
  ROUTE_NOT_FOUND: "ROUTE_NOT_FOUND",
  DIRECT_CONNECTION_STARTED: "DIRECT_CONNECTION_STARTED",
  DIRECT_CONNECTION_ESTABLISHED: "DIRECT_CONNECTION_ESTABLISHED",
  RELAY_CHANNEL_OPENED: "RELAY_CHANNEL_OPENED",
  USER_CONNECTED: "USER_CONNECTED",
  MESSAGE_CREATED: "MESSAGE_CREATED",
  MESSAGE_ENCRYPTED: "MESSAGE_ENCRYPTED",
  MESSAGE_QUEUED: "MESSAGE_QUEUED",
  MESSAGE_SENT: "MESSAGE_SENT",
  MESSAGE_RELAYED: "MESSAGE_RELAYED",
  MESSAGE_RECEIVED: "MESSAGE_RECEIVED",
  MESSAGE_DECRYPTED: "MESSAGE_DECRYPTED",
  ACK_SENT: "ACK_SENT",
  ACK_RECEIVED: "ACK_RECEIVED",
  DELIVERY_FAILED: "DELIVERY_FAILED",
  RETRY_SCHEDULED: "RETRY_SCHEDULED",
  NODE_OFFLINE: "NODE_OFFLINE",
  NODE_ONLINE: "NODE_ONLINE",
  ROUTE_EXPIRED: "ROUTE_EXPIRED",
  MODE_SWITCH: "MODE_SWITCH",
  HEARTBEAT_RECEIVED: "HEARTBEAT_RECEIVED",
  MEDIA_ENCRYPTED: "MEDIA_ENCRYPTED",
  MEDIA_UPLOADED: "MEDIA_UPLOADED",
  MEDIA_DOWNLOADED: "MEDIA_DOWNLOADED",
  MEDIA_DECRYPTED: "MEDIA_DECRYPTED",
  // Security & resilience (разделы 10, 12–20 ТЗ)
  STATE_CHANGED: "STATE_CHANGED",
  CAPACITY_ADVERTISED: "CAPACITY_ADVERTISED",
  RESOURCE_PREEMPTED: "RESOURCE_PREEMPTED",
  TASK_REJECTED: "TASK_REJECTED",
  SCAN_ATTEMPT: "SCAN_ATTEMPT",
  SCAN_REJECTED: "SCAN_REJECTED",
  REPLAY_BLOCKED: "REPLAY_BLOCKED",
  TAMPER_DETECTED: "TAMPER_DETECTED",
  ROUTE_REVOKED: "ROUTE_REVOKED",
  NODE_COMPROMISED: "NODE_COMPROMISED",
  KEY_ROTATED: "KEY_ROTATED",
  DISK_STOLEN: "DISK_STOLEN",
  SECURITY_ADVISORY: "SECURITY_ADVISORY",
  CAPABILITY_DISABLED: "CAPABILITY_DISABLED",
  CAPABILITY_RESTORED: "CAPABILITY_RESTORED",
  UPDATE_STARTED: "UPDATE_STARTED",
  UPDATE_INSTALLED: "UPDATE_INSTALLED",
  HEALTH_CHECK: "HEALTH_CHECK",
  VERSION_DEPRECATED: "VERSION_DEPRECATED",
  NETWORK_RESTRICTED: "NETWORK_RESTRICTED",
  SYBIL_DETECTED: "SYBIL_DETECTED",
  TRUST_LIMITED: "TRUST_LIMITED",
  FALLBACK_USED: "FALLBACK_USED",
  PEERS_NOTIFIED: "PEERS_NOTIFIED",
  // User & device lifecycle (§26 A/G/H/I)
  CLIENT_INSTALLED: "CLIENT_INSTALLED",
  IDENTITY_CREATED: "IDENTITY_CREATED",
  DEVICE_KEY_GENERATED: "DEVICE_KEY_GENERATED",
  NETWORK_MODE_CHOSEN: "NETWORK_MODE_CHOSEN",
  DISK_SELECTED: "DISK_SELECTED",
  LIMIT_SET: "LIMIT_SET",
  QR_GENERATED: "QR_GENERATED",
  QR_SCANNED: "QR_SCANNED",
  PAIRING_CONFIRMED: "PAIRING_CONFIRMED",
  PAIRING_TOKEN_DESTROYED: "PAIRING_TOKEN_DESTROYED",
  CONTACT_ADDED: "CONTACT_ADDED",
  FIRST_MESSAGE_SENT: "FIRST_MESSAGE_SENT",
  DEVICE_LIST_UPDATED: "DEVICE_LIST_UPDATED",
  DEVICE_LOST: "DEVICE_LOST",
  DEVICE_REVOKED: "DEVICE_REVOKED",
  RECIPIENT_SET_UPDATED: "RECIPIENT_SET_UPDATED",
  DATA_NOT_REMOTELY_ERASABLE: "DATA_NOT_REMOTELY_ERASABLE",
  IDENTITY_KEY_ROTATED: "IDENTITY_KEY_ROTATED",
  NODE_KEY_ROTATED: "NODE_KEY_ROTATED",
  CONTACT_WARNED: "CONTACT_WARNED",
  REVERIFICATION_REQUIRED: "REVERIFICATION_REQUIRED",
  REVERIFIED: "REVERIFIED",
  // Home Node recovery & storage migration (§26 J/K)
  DISK_FAILED: "DISK_FAILED",
  BACKUP_FOUND: "BACKUP_FOUND",
  BACKUP_MISSING: "BACKUP_MISSING",
  DEVICE_DATA_PRESERVED: "DEVICE_DATA_PRESERVED",
  NEW_HOME_CREATED: "NEW_HOME_CREATED",
  BACKUP_RESTORED: "BACKUP_RESTORED",
  OBJECTS_REPLICATED: "OBJECTS_REPLICATED",
  NAS_SELECTED: "NAS_SELECTED",
  STORE_COPIED: "STORE_COPIED",
  HASH_VERIFIED: "HASH_VERIFIED",
  ENDPOINT_SWITCHED: "ENDPOINT_SWITCHED",
  OLD_STORAGE_DECOMMISSIONED: "OLD_STORAGE_DECOMMISSIONED",
  // Live network scripting (30-40 user simulation)
  USER_ADDED: "USER_ADDED",
  NODE_ADDED: "NODE_ADDED",
  CONNECTION_BLOCKED: "CONNECTION_BLOCKED",
  CONNECTION_UNBLOCKED: "CONNECTION_UNBLOCKED",
  NODE_KILLED: "NODE_KILLED",
  NODE_REVIVED: "NODE_REVIVED",
  DEVICE_KEY_REVOKED: "DEVICE_KEY_REVOKED"
};
