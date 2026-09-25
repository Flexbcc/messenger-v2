import os

from shared.security.outbound_tls import validated_service_origin


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name} must be a boolean")


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


def _env_float(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be numeric") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value

# legacy  — register → trusted immediately (explicit migration mode only)
# strict  — register → pending → admin approve → node_token
# hybrid  — known node_id → trusted; new → pending (step 2+)
ENROLLMENT_MODE = os.environ.get("ENROLLMENT_MODE", "strict").lower()
if ENROLLMENT_MODE not in ("legacy", "hybrid", "strict"):
    raise RuntimeError("ENROLLMENT_MODE must be legacy, hybrid, or strict")

# Node Root / Operational Certificate migration. `report` validates and stores
# status but never changes trust_status or rejects a legacy node.
NODE_IDENTITY_MODE = os.environ.get("NODE_IDENTITY_MODE", "enforce").lower()
if NODE_IDENTITY_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("NODE_IDENTITY_MODE must be 'off', 'report', or 'enforce'")

# Root-signed monotonic credential chain. In report mode legacy portable
# requests remain accepted, while a supplied state is fully verified/stored.
OPERATIONAL_CREDENTIAL_STATE_MODE = os.environ.get(
    "OPERATIONAL_CREDENTIAL_STATE_MODE", "enforce"
).lower()
if OPERATIONAL_CREDENTIAL_STATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "OPERATIONAL_CREDENTIAL_STATE_MODE must be 'off', 'report', or 'enforce'"
    )

# Quorum revocation of one Operational Certificate serial/key.  This is
# intentionally separate from node-wide TrustRecord revocation.
OPERATIONAL_CREDENTIAL_REVOCATION_MODE = os.environ.get(
    "OPERATIONAL_CREDENTIAL_REVOCATION_MODE", "enforce"
).lower()
if OPERATIONAL_CREDENTIAL_REVOCATION_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "OPERATIONAL_CREDENTIAL_REVOCATION_MODE must be 'off', 'report', or 'enforce'"
    )

NODE_ADVERTISEMENT_MODE = os.environ.get("NODE_ADVERTISEMENT_MODE", "enforce").lower()
if NODE_ADVERTISEMENT_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("NODE_ADVERTISEMENT_MODE must be 'off', 'report', or 'enforce'")

CAPABILITY_CERTIFICATE_MODE = os.environ.get("CAPABILITY_CERTIFICATE_MODE", "enforce").lower()
if CAPABILITY_CERTIFICATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("CAPABILITY_CERTIFICATE_MODE must be 'off', 'report', or 'enforce'")
CAPABILITY_AUTHORITY_STATE_PATH = os.environ.get("CAPABILITY_AUTHORITY_STATE_PATH", "")

TRANSPORT_CERTIFICATE_MODE = os.environ.get(
    "TRANSPORT_CERTIFICATE_MODE", "enforce"
).lower()
if TRANSPORT_CERTIFICATE_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("TRANSPORT_CERTIFICATE_MODE must be 'off', 'report', or 'enforce'")

TRUST_LEDGER_MODE = os.environ.get("TRUST_LEDGER_MODE", "enforce").lower()
if TRUST_LEDGER_MODE not in ("off", "report", "enforce"):
    raise RuntimeError("TRUST_LEDGER_MODE must be 'off', 'report', or 'enforce'")
ALLOW_INSECURE_DISCOVERY_MODES = _env_bool(
    "ALLOW_INSECURE_DISCOVERY_MODES", False
)
ALLOW_LEGACY_GRANDFATHER_ALL = _env_bool(
    "ALLOW_LEGACY_GRANDFATHER_ALL", False
)
TRUST_AUTHORITY_STATE_PATH = os.environ.get(
    "TRUST_AUTHORITY_STATE_PATH", CAPABILITY_AUTHORITY_STATE_PATH
)
TRUST_LEDGER_DB_PATH = os.environ.get("TRUST_LEDGER_DB_PATH", "trust-ledger.db")
TRUST_PROPOSAL_MODE = os.environ.get("TRUST_PROPOSAL_MODE", "off").lower()
if TRUST_PROPOSAL_MODE not in ("off", "report"):
    raise RuntimeError("TRUST_PROPOSAL_MODE must be off or report")
TRUST_PROPOSAL_INTERVAL_SECONDS = _env_int(
    "TRUST_PROPOSAL_INTERVAL_SECONDS", 30, 10, 3600
)
TRUST_DEGRADATION_MODE = os.environ.get("TRUST_DEGRADATION_MODE", "observe").lower()
if TRUST_DEGRADATION_MODE not in ("off", "observe", "legacy"):
    raise RuntimeError("TRUST_DEGRADATION_MODE must be 'off', 'observe', or 'legacy'")
if TRUST_DEGRADATION_MODE == "legacy" and TRUST_LEDGER_MODE != "off":
    raise RuntimeError("legacy trust degradation requires TRUST_LEDGER_MODE=off")
TRUST_DEGRADE_L2_AFTER_DAYS = _env_int(
    "TRUST_DEGRADE_L2_AFTER_DAYS", 7, 1, 3650
)
TRUST_DEGRADE_L1_AFTER_DAYS = _env_int(
    "TRUST_DEGRADE_L1_AFTER_DAYS", 14, 1, 3650
)
if TRUST_DEGRADE_L1_AFTER_DAYS <= TRUST_DEGRADE_L2_AFTER_DAYS:
    raise RuntimeError(
        "TRUST_DEGRADE_L1_AFTER_DAYS must exceed TRUST_DEGRADE_L2_AFTER_DAYS"
    )
TRUST_DEGRADATION_CHECK_INTERVAL_SECONDS = _env_int(
    "TRUST_DEGRADATION_CHECK_INTERVAL_SECONDS", 3600, 60, 86400
)
TRUST_PROMOTION_MIN_OBSERVATIONS = _env_int(
    "TRUST_PROMOTION_MIN_OBSERVATIONS", 20, 1, 1_000_000
)
TRUST_PROMOTION_MIN_OBSERVERS = _env_int(
    "TRUST_PROMOTION_MIN_OBSERVERS", 3, 2, 10_000
)
TRUST_PROMOTION_MIN_CHALLENGE_TYPES = _env_int(
    "TRUST_PROMOTION_MIN_CHALLENGE_TYPES", 2, 1, 100
)
TRUST_PROMOTION_MIN_SUCCESS_BPS = _env_int(
    "TRUST_PROMOTION_MIN_SUCCESS_BPS", 9000, 0, 10_000
)
KEY_ROTATION_GRACE_DAYS = _env_int(
    "KEY_ROTATION_GRACE_DAYS", 3, 1, 365
)
NETWORK_VIEW_STATE_PATH = os.environ.get("NETWORK_VIEW_STATE_PATH", "network-view.json")
RECOVERY_AUTHORITY_STATE_PATH = os.environ.get("RECOVERY_AUTHORITY_STATE_PATH", "")

# After how many seconds without a heartbeat a node is considered offline.
# Configurable via env (was a hardcoded 120s). See admin-settings-spec.json
# discovery.heartbeat_timeout_s / monitor.offline_threshold_s.
OFFLINE_THRESHOLD_SECONDS = _env_int(
    "DISCOVERY_OFFLINE_THRESHOLD_SECONDS", 120, 10, 86400
)

# Admin API auth (step 3); empty = admin endpoints disabled
DISCOVERY_ADMIN_SECRET = os.environ.get("DISCOVERY_ADMIN_SECRET", "")
MESH_NOTIFY_SECRET = os.environ.get("MESH_NOTIFY_SECRET", "")
MESH_NOTIFY_ENABLED = _env_bool("MESH_NOTIFY_ENABLED", True)
MESH_NOTIFY_TIMEOUT_SECONDS = _env_float(
    "MESH_NOTIFY_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)


def validate_security_configuration() -> None:
    from shared.security.config import INTERNAL_SECURITY_MODE
    from shared.security.secret_validation import (
        require_independent_secrets,
        require_strong_secret,
    )
    from app.attestation import (
        ATTESTATION_MODE,
        MTLS_MODE,
        RELEASE_SIGNING_SECRET,
        validate_attestation_configuration,
    )

    validate_attestation_configuration()

    security_modes = {
        "ENROLLMENT_MODE": ENROLLMENT_MODE == "strict",
        "NODE_IDENTITY_MODE": NODE_IDENTITY_MODE == "enforce",
        "OPERATIONAL_CREDENTIAL_STATE_MODE": (
            OPERATIONAL_CREDENTIAL_STATE_MODE == "enforce"
        ),
        "OPERATIONAL_CREDENTIAL_REVOCATION_MODE": (
            OPERATIONAL_CREDENTIAL_REVOCATION_MODE == "enforce"
        ),
        "NODE_ADVERTISEMENT_MODE": NODE_ADVERTISEMENT_MODE == "enforce",
        "CAPABILITY_CERTIFICATE_MODE": CAPABILITY_CERTIFICATE_MODE == "enforce",
        "TRANSPORT_CERTIFICATE_MODE": TRANSPORT_CERTIFICATE_MODE == "enforce",
        "TRUST_LEDGER_MODE": TRUST_LEDGER_MODE == "enforce",
        "ATTESTATION_MODE": ATTESTATION_MODE == "enforce",
        "MTLS_MODE": MTLS_MODE == "enforce",
    }
    downgraded = [name for name, secure in security_modes.items() if not secure]
    if downgraded and not ALLOW_INSECURE_DISCOVERY_MODES:
        raise RuntimeError(
            "Discovery security downgrade requires "
            "ALLOW_INSECURE_DISCOVERY_MODES=true: "
            + ", ".join(downgraded)
        )

    require_strong_secret("MESH_NOTIFY_SECRET", MESH_NOTIFY_SECRET)
    if DISCOVERY_ADMIN_SECRET:
        require_strong_secret("DISCOVERY_ADMIN_SECRET", DISCOVERY_ADMIN_SECRET)

    if INTERNAL_SECURITY_MODE == "signed":
        if RELEASE_SIGNING_SECRET:
            raise RuntimeError(
                "RELEASE_SIGNING_SECRET is a legacy HMAC authority and must be "
                "unset in signed mode"
            )
        require_strong_secret("DISCOVERY_ADMIN_SECRET", DISCOVERY_ADMIN_SECRET)
    elif RELEASE_SIGNING_SECRET:
        require_strong_secret("RELEASE_SIGNING_SECRET", RELEASE_SIGNING_SECRET)

    configured_secrets = {"MESH_NOTIFY_SECRET": MESH_NOTIFY_SECRET}
    if DISCOVERY_ADMIN_SECRET:
        configured_secrets["DISCOVERY_ADMIN_SECRET"] = DISCOVERY_ADMIN_SECRET
    if RELEASE_SIGNING_SECRET:
        configured_secrets["RELEASE_SIGNING_SECRET"] = RELEASE_SIGNING_SECRET
    require_independent_secrets(configured_secrets)

# --- Active health-check (Node Monitor) — ADR-0006 follow-up ---------------
# Discovery periodically pings the real /health endpoint of registered nodes to
# refine reachability beyond passive heartbeat freshness. Disabled by default so
# behaviour is backward compatible.
HEALTHCHECK_ENABLED = _env_bool("DISCOVERY_HEALTHCHECK_ENABLED", False)
HEALTHCHECK_INTERVAL_SECONDS = _env_int(
    "DISCOVERY_HEALTHCHECK_INTERVAL_SECONDS", 30, 5, 3600
)
HEALTHCHECK_TIMEOUT_SECONDS = _env_float(
    "DISCOVERY_HEALTHCHECK_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

# --- Vulnerability response defaults (seed values for discovery_settings) ---
# Quarantine mode for nodes running a blocked/vulnerable version:
#   off     — do nothing
#   warn    — keep node listed, flag version_status=blocked
#   isolate — exclude node from discovery listings (relay/storage/discovery roles)
QUARANTINE_MODE_DEFAULT = os.environ.get("DISCOVERY_QUARANTINE_MODE", "warn").lower()
if QUARANTINE_MODE_DEFAULT not in {"off", "warn", "isolate"}:
    raise RuntimeError("DISCOVERY_QUARANTINE_MODE must be off, warn, or isolate")
FORCE_UPGRADE_DEFAULT = _env_bool("DISCOVERY_FORCE_UPGRADE", True)

# Discovery signing key — used to sign user records (user_id→home_node_url).
# Home-nodes verify the signature before trusting the resolved address.
DISCOVERY_SIGNING_KEY_PATH = os.environ.get(
    "DISCOVERY_SIGNING_KEY_PATH", "/data/discovery_signing.key"
)

# Node Root/Operational identity is deliberately separate from the key used to
# sign cached directory records.
DISCOVERY_NODE_ALIAS = os.environ.get("DISCOVERY_NODE_ID", "discovery-local")
DISCOVERY_NODE_PUBLIC_URL = validated_service_origin(
    os.environ.get("DISCOVERY_NODE_PUBLIC_URL", "http://localhost:8003"),
    "DISCOVERY_NODE_PUBLIC_URL",
)
FEDERATION_NONCE_DB_PATH = os.environ.get(
    "FEDERATION_NONCE_DB_PATH", "/data/discovery_federation_nonces.db"
)
FEDERATION_AUDIT_DB_PATH = os.environ.get(
    "FEDERATION_AUDIT_DB_PATH", "/data/discovery_federation_audit.db"
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


class DiscoveryRegistrationSettings:
    """Adapter for the shared signed node-registration lifecycle."""

    node_id = DISCOVERY_NODE_ALIAS
    public_url = DISCOVERY_NODE_PUBLIC_URL
    discovery_url = validated_service_origin(
        os.environ.get("DISCOVERY_NODE_URL", DISCOVERY_NODE_PUBLIC_URL),
        "DISCOVERY_NODE_URL",
    )
    capabilities = ["discovery"]
    software_version = os.environ.get("NODE_SOFTWARE_VERSION", "0.2.0")
    cluster_id = os.environ.get("CLUSTER_ID", "default")
    enrollment_mode = ENROLLMENT_MODE
    node_token_path = os.environ.get("NODE_TOKEN_PATH", "/data/node_token")
    enrollment_secret_path = os.environ.get(
        "ENROLLMENT_SECRET_PATH", "/data/enrollment_secret"
    )
    build_hash = os.environ.get("NODE_BUILD_HASH", "")
    tls_cert_fingerprint = os.environ.get("NODE_TLS_CERT_FINGERPRINT", "")
    release_signature = os.environ.get("NODE_RELEASE_SIGNATURE", "")
    signing_key_path = DISCOVERY_NODE_OPERATIONAL_KEY_PATH
    root_key_path = DISCOVERY_NODE_ROOT_KEY_PATH
    operational_certificate_path = DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH
    operational_credential_chain_path = os.environ.get(
        "NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH", ""
    )
    capability_certificate_path = os.environ.get(
        "NODE_CAPABILITY_CERTIFICATE_PATH", ""
    )
    capability_authority_state_path = os.environ.get(
        "NODE_CAPABILITY_AUTHORITY_STATE_PATH", CAPABILITY_AUTHORITY_STATE_PATH
    )
    transport_key_path = os.environ.get("NODE_TRANSPORT_KEY_PATH", "")
    transport_certificate_path = os.environ.get(
        "NODE_TRANSPORT_CERTIFICATE_PATH", ""
    )


discovery_registration_settings = DiscoveryRegistrationSettings()
DISCOVERY_SELF_REGISTRATION_ENABLED = _env_bool(
    "DISCOVERY_SELF_REGISTRATION_ENABLED", False
)

AUTHORITY_GOSSIP_ENABLED = _env_bool("AUTHORITY_GOSSIP_ENABLED", False)
AUTHORITY_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("AUTHORITY_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
AUTHORITY_GOSSIP_INTERVAL_SECONDS = _env_int(
    "AUTHORITY_GOSSIP_INTERVAL_SECONDS", 30, 5, 3600
)
AUTHORITY_GOSSIP_TIMEOUT_SECONDS = _env_float(
    "AUTHORITY_GOSSIP_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

NODE_ADVERTISEMENT_GOSSIP_ENABLED = _env_bool(
    "NODE_ADVERTISEMENT_GOSSIP_ENABLED", False
)
NODE_ADVERTISEMENT_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("NODE_ADVERTISEMENT_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS = _env_int(
    "NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS", 30, 5, 3600
)
NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS = _env_float(
    "NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

TRUST_RECORD_GOSSIP_ENABLED = _env_bool("TRUST_RECORD_GOSSIP_ENABLED", False)
TRUST_RECORD_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("TRUST_RECORD_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
TRUST_RECORD_GOSSIP_INTERVAL_SECONDS = _env_int(
    "TRUST_RECORD_GOSSIP_INTERVAL_SECONDS", 30, 5, 3600
)
TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS = _env_float(
    "TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

RENDEZVOUS_GOSSIP_ENABLED = _env_bool("RENDEZVOUS_GOSSIP_ENABLED", False)
RENDEZVOUS_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("RENDEZVOUS_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
RENDEZVOUS_GOSSIP_INTERVAL_SECONDS = _env_int(
    "RENDEZVOUS_GOSSIP_INTERVAL_SECONDS", 30, 5, 3600
)
RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS = _env_float(
    "RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED = _env_bool(
    "CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED", False
)
CHALLENGE_ASSIGNMENT_GOSSIP_PEERS = tuple(
    item.strip().rstrip("/")
    for item in os.environ.get("CHALLENGE_ASSIGNMENT_GOSSIP_PEERS", "").split(",")
    if item.strip()
)
CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS = _env_int(
    "CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS", 30, 5, 3600
)
CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS = _env_float(
    "CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS", 5.0, 0.1, 60.0
)

CHALLENGE_PROPOSAL_SCHEDULER_MODE = os.environ.get(
    "CHALLENGE_PROPOSAL_SCHEDULER_MODE", "off"
).lower()
if CHALLENGE_PROPOSAL_SCHEDULER_MODE not in ("off", "report", "enforce"):
    raise RuntimeError(
        "CHALLENGE_PROPOSAL_SCHEDULER_MODE must be off, report, or enforce"
    )
CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS = _env_int(
    "CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS", 30, 10, 3600
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
