import os


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int, *, min_v: int = 0, max_v: int = 100) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return max(min_v, min(max_v, value))


def _env_choice(name: str, default: str, choices: tuple[str, ...]) -> str:
    value = os.environ.get(name, default).strip().lower()
    if value not in choices:
        raise RuntimeError(f"{name} must be one of: {', '.join(choices)}")
    return value


class Settings:
    node_id: str = os.environ.get("HOME_NODE_ID", "home-local")
    public_url: str = os.environ.get("HOME_NODE_PUBLIC_URL", "http://localhost:8001")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")
    route_discovery_urls: tuple[str, ...] = tuple(
        dict.fromkeys(
            value.strip().rstrip("/")
            for value in os.environ.get(
                "ROUTE_DISCOVERY_URLS", os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")
            ).split(",")
            if value.strip()
        )
    )
    route_resolution_mode: str = _env_choice(
        "ROUTE_RESOLUTION_MODE", "off", ("off", "report", "enforce")
    )
    route_minimum_discovery_sources: int = _env_int(
        "ROUTE_MINIMUM_DISCOVERY_SOURCES", 2, min_v=1, max_v=16
    )
    route_runtime_state_path: str = os.environ.get(
        "ROUTE_RUNTIME_STATE_PATH", "/data/route-runtime-state.json"
    )
    transport_route_hops: int = _env_int(
        "TRANSPORT_ROUTE_HOPS", 3, min_v=2, max_v=4
    )
    # Post-R5: short in-memory TTL for resolve_home_node (see
    # docs/reality/R4-routing.md Gaps "Нет TTL/кэша user→home"). 0 disables caching.
    discovery_resolve_cache_ttl_seconds: int = int(
        os.environ.get("DISCOVERY_RESOLVE_CACHE_TTL_SECONDS", "60")
    )
    # Last-known signed route may be used only when Discovery is unreachable.
    # This is an availability bridge until user-signed RouteDescriptor exists.
    discovery_resolve_stale_if_error_seconds: int = int(
        os.environ.get("DISCOVERY_RESOLVE_STALE_IF_ERROR_SECONDS", "86400")
    )
    storage_node_url: str = os.environ.get("STORAGE_NODE_URL", "http://localhost:8002")
    storage_node_urls: tuple[str, ...] = tuple(
        dict.fromkeys(
            value.strip().rstrip("/")
            for value in os.environ.get("STORAGE_NODE_URLS", storage_node_url).split(",")
            if value.strip()
        )
    ) or (storage_node_url.rstrip("/"),)
    storage_replication_factor: int = _env_int(
        "STORAGE_REPLICATION_FACTOR", 1, min_v=1, max_v=5
    )
    storage_write_quorum: int = _env_int(
        "STORAGE_WRITE_QUORUM", 1, min_v=1, max_v=5
    )
    if storage_write_quorum > storage_replication_factor:
        raise RuntimeError("STORAGE_WRITE_QUORUM cannot exceed STORAGE_REPLICATION_FACTOR")
    db_path: str = os.environ.get("HOME_DB_PATH", "home.db")
    jwt_secret: str = os.environ.get("JWT_SECRET", "dev-secret-change-me-in-production")
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7  # 7 days
    challenge_ttl_seconds: int = 120

    # Operator/cluster label — groups nodes that belong to the same infrastructure
    # owner (public pool, corp island, self-hosted). See NODE_RESOURCE_POLICY.
    cluster_id: str = os.environ.get("CLUSTER_ID", "default")

    # How Home Node picks auxiliary nodes (relay/storage) from Discovery:
    #   cluster    — only nodes with the same CLUSTER_ID (local/private cluster)
    #   federated  — any online node in Discovery (public federated network)
    #   local      — fixed STORAGE_NODE_URL env only; no relay fallback via Discovery
    resource_policy: str = os.environ.get("NODE_RESOURCE_POLICY", "federated")
    # Basic Relay transport. HTTP remains available as a diagnostic/fallback
    # control path; secure deployments prefer the persistent binary adapter.
    relay_transport_mode: str = _env_choice(
        "RELAY_TRANSPORT_MODE",
        "http",
        ("http", "websocket-preferred", "websocket-required"),
    )
    signed_peer_selection_mode: str = _env_choice(
        "SIGNED_PEER_SELECTION_MODE",
        "off",
        ("off", "report", "enforce"),
    )
    peer_discovery_urls: tuple[str, ...] = tuple(
        value.strip().rstrip("/")
        for value in os.environ.get("PEER_DISCOVERY_URLS", "").split(",")
        if value.strip()
    )
    peer_authority_state_path: str = os.environ.get("PEER_AUTHORITY_STATE_PATH", "")
    peer_discovery_source_set_path: str = os.environ.get(
        "PEER_DISCOVERY_SOURCE_SET_PATH", ""
    )
    peer_selection_seed_path: str = os.environ.get(
        "PEER_SELECTION_SEED_PATH", "/data/peer-selection.seed"
    )
    peer_selection_state_path: str = os.environ.get(
        "PEER_SELECTION_STATE_PATH", "/data/peer-selection-state.json"
    )
    peer_selection_refresh_seconds: int = max(
        30, min(300, int(os.environ.get("PEER_SELECTION_REFRESH_SECONDS", "60")))
    )
    peer_selection_rotation_seconds: int = max(
        300, min(86400, int(os.environ.get("PEER_SELECTION_ROTATION_SECONDS", "3600")))
    )

    # How much of free capacity helps the federation vs owner-first traffic.
    # Applied later by schedulers; monitored and editable via Admin now.
    owner_resource_percent: int = _env_int("OWNER_RESOURCE_PERCENT", 40)

    # Opt-in participation flags — what this node is willing to do for the network.
    participate_relay: bool = _env_bool("NODE_PARTICIPATE_RELAY", True)
    participate_storage: bool = _env_bool("NODE_PARTICIPATE_STORAGE", True)
    participate_witness: bool = _env_bool("NODE_PARTICIPATE_WITNESS", False)
    participate_media_cache: bool = _env_bool("NODE_PARTICIPATE_MEDIA_CACHE", False)
    participate_nat_assist: bool = _env_bool("NODE_PARTICIPATE_NAT_ASSIST", False)

    enrollment_mode: str = os.environ.get("ENROLLMENT_MODE", "legacy").lower()
    node_token_path: str = os.environ.get("NODE_TOKEN_PATH", "/data/node_token")
    enrollment_secret_path: str = os.environ.get("ENROLLMENT_SECRET_PATH", "/data/enrollment_secret")

    build_hash: str = os.environ.get("NODE_BUILD_HASH", "")
    tls_cert_fingerprint: str = os.environ.get("NODE_TLS_CERT_FINGERPRINT", "")
    release_signature: str = os.environ.get("NODE_RELEASE_SIGNATURE", "")

    signing_key_path: str = os.environ.get("NODE_SIGNING_KEY_PATH", "/data/node_signing_key")
    root_key_path: str = os.environ.get("NODE_ROOT_KEY_PATH", "/data/node_root_key")
    operational_certificate_path: str = os.environ.get(
        "NODE_OPERATIONAL_CERTIFICATE_PATH", "/data/node_operational_certificate.json"
    )
    operational_credential_chain_path: str = os.environ.get(
        "NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH", ""
    )
    capability_certificate_path: str = os.environ.get("NODE_CAPABILITY_CERTIFICATE_PATH", "")
    transport_key_path: str = os.environ.get("NODE_TRANSPORT_KEY_PATH", "/data/node_transport_key")
    transport_certificate_path: str = os.environ.get(
        "NODE_TRANSPORT_CERTIFICATE_PATH", "/data/node_transport_certificate.json"
    )
    mix_replay_db_path: str = os.environ.get("MIX_REPLAY_DB_PATH", "/data/mix_replay.db")
    mix_replay_ttl_seconds: int = _env_int(
        "MIX_REPLAY_TTL_SECONDS", 86400, min_v=60, max_v=2_592_000
    )
    mix_replay_max_records: int = _env_int(
        "MIX_REPLAY_MAX_RECORDS", 100000, min_v=100, max_v=10_000_000
    )
    mix_pool_max_cells: int = _env_int(
        "MIX_POOL_MAX_CELLS", 2048, min_v=1, max_v=100_000
    )
    mix_pool_max_bytes: int = _env_int(
        "MIX_POOL_MAX_BYTES", 134217728, min_v=4096, max_v=2_147_483_647
    )
    mix_min_delay_ms: int = _env_int(
        "MIX_MIN_DELAY_MS", 100, min_v=0, max_v=60_000
    )
    mix_max_delay_ms: int = _env_int(
        "MIX_MAX_DELAY_MS", 2000, min_v=1, max_v=300_000
    )
    if mix_max_delay_ms < mix_min_delay_ms:
        raise RuntimeError("MIX_MAX_DELAY_MS cannot be below MIX_MIN_DELAY_MS")
    onion_provider_mode: str = _env_choice(
        "ONION_PROVIDER_MODE", "off", ("off", "sidecar")
    )
    onion_sidecar_socket_path: str = os.environ.get(
        "ONION_SIDECAR_SOCKET_PATH", "/run/ouo-sphinx/provider.sock"
    )
    capability_authority_state_path: str = os.environ.get(
        "NODE_CAPABILITY_AUTHORITY_STATE_PATH", ""
    )
    # Sealed sender (Task #68): X25519 key для шифрования sender_user_id от relay-нод
    curve_key_path: str = os.environ.get("NODE_CURVE_KEY_PATH", "/data/node_curve_key")
    federation_nonce_db_path: str = os.environ.get("FEDERATION_NONCE_DB_PATH", "/data/federation_nonces.db")
    federation_audit_db_path: str = os.environ.get("FEDERATION_AUDIT_DB_PATH", "/data/federation_audit.db")
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")
    federation_envelope_mode: str = os.environ.get("FEDERATION_ENVELOPE_MODE", "legacy")

    # Push proxy — для уведомлений о входящем звонке (Task #17)
    push_proxy_url: str | None = os.environ.get("PUSH_PROXY_URL")   # None = disabled
    push_proxy_secret: str = os.environ.get("PUSH_PROXY_SECRET", "changeme")

    media_node_url: str = os.environ.get("MEDIA_NODE_URL", "http://localhost:8004")
    media_access_secret: str = os.environ.get("MEDIA_ACCESS_SECRET", "") or os.environ.get(
        "JWT_SECRET", "dev-secret-change-me-in-production"
    )
    media_access_ttl_seconds: int = int(os.environ.get("MEDIA_ACCESS_TTL_SECONDS", "300"))

    # Bootstrap-phase registration/monitoring — see ADR-0006.
    capabilities: list = ["home"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")


settings = Settings()
