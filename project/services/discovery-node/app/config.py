import os

# legacy  — register → trusted immediately (default, backward compatible)
# strict  — register → pending → admin approve → node_token
# hybrid  — known node_id → trusted; new → pending (step 2+)
ENROLLMENT_MODE = os.environ.get("ENROLLMENT_MODE", "legacy").lower()

# After how many seconds without a heartbeat a node is considered offline.
# Configurable via env (was a hardcoded 120s). See admin-settings-spec.json
# discovery.heartbeat_timeout_s / monitor.offline_threshold_s.
OFFLINE_THRESHOLD_SECONDS = int(os.environ.get("DISCOVERY_OFFLINE_THRESHOLD_SECONDS", "120"))

# Admin API auth (step 3); empty = admin endpoints disabled
DISCOVERY_ADMIN_SECRET = os.environ.get("DISCOVERY_ADMIN_SECRET", "")

# --- Active health-check (Node Monitor) — ADR-0006 follow-up ---------------
# Discovery periodically pings the real /health endpoint of registered nodes to
# refine reachability beyond passive heartbeat freshness. Disabled by default so
# behaviour is backward compatible.
HEALTHCHECK_ENABLED = os.environ.get("DISCOVERY_HEALTHCHECK_ENABLED", "false").lower() in ("1", "true", "yes", "on")
HEALTHCHECK_INTERVAL_SECONDS = int(os.environ.get("DISCOVERY_HEALTHCHECK_INTERVAL_SECONDS", "30"))
HEALTHCHECK_TIMEOUT_SECONDS = float(os.environ.get("DISCOVERY_HEALTHCHECK_TIMEOUT_SECONDS", "5"))

# --- Vulnerability response defaults (seed values for discovery_settings) ---
# Quarantine mode for nodes running a blocked/vulnerable version:
#   off     — do nothing
#   warn    — keep node listed, flag version_status=blocked
#   isolate — exclude node from discovery listings (relay/storage/discovery roles)
QUARANTINE_MODE_DEFAULT = os.environ.get("DISCOVERY_QUARANTINE_MODE", "warn").lower()
FORCE_UPGRADE_DEFAULT = os.environ.get("DISCOVERY_FORCE_UPGRADE", "true").lower() in ("1", "true", "yes", "on")

# Discovery signing key — used to sign user records (user_id→home_node_url).
# Home-nodes verify the signature before trusting the resolved address.
DISCOVERY_SIGNING_KEY_PATH = os.environ.get(
    "DISCOVERY_SIGNING_KEY_PATH", "/data/discovery_signing.key"
)

TRUST_STATUSES = frozenset({"pending", "trusted", "suspended", "compromised", "unknown"})
REACHABILITY_ONLINE = "online"
REACHABILITY_OFFLINE = "offline"
REACHABILITY_UNREACHABLE = "unreachable"

QUARANTINE_MODES = frozenset({"off", "warn", "isolate"})
VERSION_STATUS_OK = "ok"
VERSION_STATUS_BLOCKED = "blocked"
