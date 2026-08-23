import os

# legacy  — register → trusted immediately (default, backward compatible)
# strict  — register → pending → admin approve → node_token
# hybrid  — known node_id → trusted; new → pending (step 2+)
ENROLLMENT_MODE = os.environ.get("ENROLLMENT_MODE", "legacy").lower()

# Node Root / Operational Certificate migration. `report` validates and stores
# status but never changes trust_status or rejects a legacy node.
NODE_IDENTITY_MODE = os.environ.get("NODE_IDENTITY_MODE", "report").lower()
if NODE_IDENTITY_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("NODE_IDENTITY_MODE must be 'off', 'report', or 'enforce'")

# Root-signed monotonic credential chain. In report mode legacy portable
# requests remain accepted, while a supplied state is fully verified/stored.
OPERATIONAL_CREDENTIAL_STATE_MODE = os.environ.get(
    "OPERATIONAL_CREDENTIAL_STATE_MODE", "report"
).lower()
if OPERATIONAL_CREDENTIAL_STATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "OPERATIONAL_CREDENTIAL_STATE_MODE must be 'off', 'report', or 'enforce'"
    )

# Quorum revocation of one Operational Certificate serial/key.  This is
# intentionally separate from node-wide TrustRecord revocation.
OPERATIONAL_CREDENTIAL_REVOCATION_MODE = os.environ.get(
    "OPERATIONAL_CREDENTIAL_REVOCATION_MODE", "report"
).lower()
if OPERATIONAL_CREDENTIAL_REVOCATION_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "OPERATIONAL_CREDENTIAL_REVOCATION_MODE must be 'off', 'report', or 'enforce'"
    )

NODE_ADVERTISEMENT_MODE = os.environ.get("NODE_ADVERTISEMENT_MODE", "report").lower()
if NODE_ADVERTISEMENT_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("NODE_ADVERTISEMENT_MODE must be 'off', 'report', or 'enforce'")

CAPABILITY_CERTIFICATE_MODE = os.environ.get("CAPABILITY_CERTIFICATE_MODE", "report").lower()
if CAPABILITY_CERTIFICATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("CAPABILITY_CERTIFICATE_MODE must be 'off', 'report', or 'enforce'")
CAPABILITY_AUTHORITY_STATE_PATH = os.environ.get("CAPABILITY_AUTHORITY_STATE_PATH", "")

TRANSPORT_CERTIFICATE_MODE = os.environ.get(
    "TRANSPORT_CERTIFICATE_MODE", "report"
).lower()
if TRANSPORT_CERTIFICATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("TRANSPORT_CERTIFICATE_MODE must be 'off', 'report', or 'enforce'")

TRUST_LEDGER_MODE = os.environ.get("TRUST_LEDGER_MODE", "report").lower()
if TRUST_LEDGER_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("TRUST_LEDGER_MODE must be 'off', 'report', or 'enforce'")
TRUST_AUTHORITY_STATE_PATH = os.environ.get(
    "TRUST_AUTHORITY_STATE_PATH", CAPABILITY_AUTHORITY_STATE_PATH
)
TRUST_LEDGER_DB_PATH = os.environ.get("TRUST_LEDGER_DB_PATH", "trust-ledger.db")
TRUST_PROPOSAL_MODE = os.environ.get("TRUST_PROPOSAL_MODE", "off").lower()
if TRUST_PROPOSAL_MODE not in ("off", "report"):
    raise RuntimeError("TRUST_PROPOSAL_MODE must be off or report")
TRUST_PROPOSAL_INTERVAL_SECONDS = max(
    10, int(os.environ.get("TRUST_PROPOSAL_INTERVAL_SECONDS", "30"))
)
TRUST_DEGRADATION_MODE = os.environ.get("TRUST_DEGRADATION_MODE", "observe").lower()
if TRUST_DEGRADATION_MODE not in ("off", "observe", "legacy"):
    raise RuntimeError("TRUST_DEGRADATION_MODE must be 'off', 'observe', or 'legacy'")
if TRUST_DEGRADATION_MODE == "legacy" and TRUST_LEDGER_MODE != "off":
    raise RuntimeError("legacy trust degradation requires TRUST_LEDGER_MODE=off")
NETWORK_VIEW_STATE_PATH = os.environ.get("NETWORK_VIEW_STATE_PATH", "network-view.json")
RECOVERY_AUTHORITY_STATE_PATH = os.environ.get("RECOVERY_AUTHORITY_STATE_PATH", "")

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

# Node Root/Operational identity is deliberately separate from the key used to
# sign cached directory records.
DISCOVERY_NODE_ALIAS = os.environ.get("DISCOVERY_NODE_ID", "discovery-local")
DISCOVERY_NODE_PUBLIC_URL = os.environ.get(
    "DISCOVERY_NODE_PUBLIC_URL", "http://localhost:8003"
)
DISCOVERY_NODE_ROOT_KEY_PATH = os.environ.get(
    "NODE_ROOT_KEY_PATH", "/data/discovery_node_root.key"
)
DISCOVERY_NODE_OPERATIONAL_KEY_PATH = os.environ.get(
    "NODE_SIGNING_KEY_PATH", "/data/discovery_node_operational.key"
)
DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH = os.environ.get(
    "NODE_OPERATIONAL_CERTIFICATE_PATH",
    "/data/discovery_node_operational_certificate.json",
)

AUTHORITY_GOSSIP_ENABLED = os.environ.get(
    "AUTHORITY_GOSSIP_ENABLED", "false"
).lower() in ("1", "true", "yes", "on")
AUTHORITY_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("AUTHORITY_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
AUTHORITY_GOSSIP_INTERVAL_SECONDS = max(
    5, int(os.environ.get("AUTHORITY_GOSSIP_INTERVAL_SECONDS", "30"))
)
AUTHORITY_GOSSIP_TIMEOUT_SECONDS = max(
    1.0, float(os.environ.get("AUTHORITY_GOSSIP_TIMEOUT_SECONDS", "5"))
)

NODE_ADVERTISEMENT_GOSSIP_ENABLED = os.environ.get(
    "NODE_ADVERTISEMENT_GOSSIP_ENABLED", "false"
).lower() in ("1", "true", "yes", "on")
NODE_ADVERTISEMENT_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("NODE_ADVERTISEMENT_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS = max(
    5, int(os.environ.get("NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS", "30"))
)
NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS = max(
    1.0, float(os.environ.get("NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS", "5"))
)

TRUST_RECORD_GOSSIP_ENABLED = os.environ.get(
    "TRUST_RECORD_GOSSIP_ENABLED", "false"
).lower() in ("1", "true", "yes", "on")
TRUST_RECORD_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("TRUST_RECORD_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
TRUST_RECORD_GOSSIP_INTERVAL_SECONDS = max(
    5, int(os.environ.get("TRUST_RECORD_GOSSIP_INTERVAL_SECONDS", "30"))
)
TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS = max(
    1.0, float(os.environ.get("TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS", "5"))
)

RENDEZVOUS_GOSSIP_ENABLED = os.environ.get(
    "RENDEZVOUS_GOSSIP_ENABLED", "false"
).lower() in ("1", "true", "yes", "on")
RENDEZVOUS_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("RENDEZVOUS_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
RENDEZVOUS_GOSSIP_INTERVAL_SECONDS = max(
    5, int(os.environ.get("RENDEZVOUS_GOSSIP_INTERVAL_SECONDS", "30"))
)
RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS = max(
    1.0, float(os.environ.get("RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS", "5"))
)

CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED = os.environ.get(
    "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED", "false"
).lower() in ("1", "true", "yes", "on")
CHALLENGE_ASSIGNMENT_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("CHALLENGE_ASSIGNMENT_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS = max(
    5, int(os.environ.get("CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS", "30"))
)
CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS = max(
    1.0, float(os.environ.get("CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS", "5"))
)

CHALLENGE_PROPOSAL_SCHEDULER_MODE = os.environ.get(
    "CHALLENGE_PROPOSAL_SCHEDULER_MODE", "off"
).lower()
if CHALLENGE_PROPOSAL_SCHEDULER_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "CHALLENGE_PROPOSAL_SCHEDULER_MODE must be off, report, or enforce"
    )
CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS = max(
    10, int(os.environ.get("CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS", "30"))
)

RANDOMNESS_CHECKPOINT_MODE = os.environ.get(
    "RANDOMNESS_CHECKPOINT_MODE", "report"
).lower()
if RANDOMNESS_CHECKPOINT_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "RANDOMNESS_CHECKPOINT_MODE must be 'off', 'report', or 'enforce'"
    )

TRUST_STATUSES = frozenset({"pending", "trusted", "suspended", "compromised", "unknown"})
REACHABILITY_ONLINE = "online"
REACHABILITY_OFFLINE = "offline"
REACHABILITY_UNREACHABLE = "unreachable"

QUARANTINE_MODES = frozenset({"off", "warn", "isolate"})
VERSION_STATUS_OK = "ok"
VERSION_STATUS_BLOCKED = "blocked"
