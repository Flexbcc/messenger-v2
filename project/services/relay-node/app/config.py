import os


def _bounded_int(name: str, default: int, *, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


class Settings:
    node_id: str = os.environ.get("RELAY_NODE_ID", "relay-local")
    public_url: str = os.environ.get("RELAY_NODE_PUBLIC_URL", "http://localhost:8005")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")
    mix_discovery_urls: tuple[str, ...] = tuple(
        dict.fromkeys(
            value.strip().rstrip("/")
            for value in os.environ.get(
                "MIX_DISCOVERY_URLS", discovery_url
            ).split(",")
            if value.strip()
        )
    )
    mix_minimum_discovery_sources: int = _bounded_int(
        "MIX_MINIMUM_DISCOVERY_SOURCES", 2, minimum=2, maximum=16
    )
    mix_peer_cache_ttl_seconds: int = _bounded_int(
        "MIX_PEER_CACHE_TTL_SECONDS", 60, minimum=5, maximum=300
    )
    mix_peer_cache_max_records: int = _bounded_int(
        "MIX_PEER_CACHE_MAX_RECORDS", 1000, minimum=10, maximum=10_000
    )

    capabilities: list = ["relay"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")
    cluster_id: str = os.environ.get("CLUSTER_ID", "default")

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
    capability_authority_state_path: str = os.environ.get(
        "NODE_CAPABILITY_AUTHORITY_STATE_PATH", ""
    )
    federation_nonce_db_path: str = os.environ.get("FEDERATION_NONCE_DB_PATH", "/data/federation_nonces.db")
    federation_audit_db_path: str = os.environ.get("FEDERATION_AUDIT_DB_PATH", "/data/federation_audit.db")
    link_sequence_db_path: str = os.environ.get(
        "RELAY_LINK_SEQUENCE_DB_PATH", "/data/relay_link_sequences.db"
    )
    link_sequence_ttl_seconds: int = _bounded_int(
        "RELAY_LINK_SEQUENCE_TTL_SECONDS", 86400, minimum=60, maximum=2_592_000
    )
    link_sequence_max_records: int = _bounded_int(
        "RELAY_LINK_SEQUENCE_MAX_RECORDS", 100000, minimum=100, maximum=10_000_000
    )
    mix_replay_db_path: str = os.environ.get(
        "MIX_REPLAY_DB_PATH", "/data/mix_replay.db"
    )
    mix_replay_ttl_seconds: int = _bounded_int(
        "MIX_REPLAY_TTL_SECONDS", 86400, minimum=60, maximum=2_592_000
    )
    mix_replay_max_records: int = _bounded_int(
        "MIX_REPLAY_MAX_RECORDS", 100000, minimum=100, maximum=10_000_000
    )
    mix_pool_max_cells: int = _bounded_int(
        "MIX_POOL_MAX_CELLS", 2048, minimum=1, maximum=100_000
    )
    mix_pool_max_bytes: int = _bounded_int(
        "MIX_POOL_MAX_BYTES", 134217728, minimum=4096, maximum=2_147_483_647
    )
    mix_min_delay_ms: int = _bounded_int(
        "MIX_MIN_DELAY_MS", 100, minimum=0, maximum=60_000
    )
    mix_max_delay_ms: int = _bounded_int(
        "MIX_MAX_DELAY_MS", 2000, minimum=1, maximum=300_000
    )
    mix_drain_batch: int = _bounded_int(
        "MIX_DRAIN_BATCH", 64, minimum=1, maximum=1024
    )
    if mix_max_delay_ms < mix_min_delay_ms:
        raise RuntimeError("MIX_MAX_DELAY_MS cannot be below MIX_MIN_DELAY_MS")
    onion_provider_mode: str = os.environ.get("ONION_PROVIDER_MODE", "off").lower()
    if onion_provider_mode not in ("off", "sidecar"):
        raise RuntimeError("ONION_PROVIDER_MODE must be off or sidecar")
    onion_sidecar_socket_path: str = os.environ.get(
        "ONION_SIDECAR_SOCKET_PATH", "/run/ouo-sphinx/provider.sock"
    )
    ws_max_connections: int = _bounded_int(
        "RELAY_WS_MAX_CONNECTIONS", 100, minimum=1, maximum=100_000
    )
    ws_max_connections_per_peer: int = _bounded_int(
        "RELAY_WS_MAX_CONNECTIONS_PER_PEER", 4, minimum=1, maximum=1_000
    )
    ws_max_cells_per_batch: int = _bounded_int(
        "RELAY_WS_MAX_CELLS_PER_BATCH", 32, minimum=1, maximum=256
    )
    ws_idle_timeout_seconds: int = _bounded_int(
        "RELAY_WS_IDLE_TIMEOUT_SECONDS", 60, minimum=5, maximum=3_600
    )
    ws_cell_timeout_seconds: int = _bounded_int(
        "RELAY_WS_CELL_TIMEOUT_SECONDS", 20, minimum=1, maximum=300
    )
    ws_send_timeout_seconds: int = _bounded_int(
        "RELAY_WS_SEND_TIMEOUT_SECONDS", 10, minimum=1, maximum=120
    )
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")

    # Rate-limit транзитных сообщений (Фаза 3.2)
    # Максимум запросов от одного origin_node_id за окно RELAY_RATE_WINDOW_SECONDS.
    relay_rate_limit: int = int(os.environ.get("RELAY_RATE_LIMIT", "100"))
    relay_rate_window_seconds: int = int(os.environ.get("RELAY_RATE_WINDOW_SECONDS", "60"))
    # off|report|enforce. Enforce requires target Home URL to be present in the
    # trusted Discovery catalog and blocks generic SSRF-style forwarding.
    target_validation_mode: str = os.environ.get("RELAY_TARGET_VALIDATION_MODE", "report").lower()
    if target_validation_mode not in ("off", "report", "enforce"):
        raise RuntimeError("RELAY_TARGET_VALIDATION_MODE must be off, report, or enforce")

    if ws_max_connections_per_peer > ws_max_connections:
        raise RuntimeError(
            "RELAY_WS_MAX_CONNECTIONS_PER_PEER cannot exceed RELAY_WS_MAX_CONNECTIONS"
        )


settings = Settings()
