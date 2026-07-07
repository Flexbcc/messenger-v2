import os


class Settings:
    node_id: str = os.environ.get("HOME_NODE_ID", "home-local")
    public_url: str = os.environ.get("HOME_NODE_PUBLIC_URL", "http://localhost:8001")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")
    storage_node_url: str = os.environ.get("STORAGE_NODE_URL", "http://localhost:8002")
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

    enrollment_mode: str = os.environ.get("ENROLLMENT_MODE", "legacy").lower()
    node_token_path: str = os.environ.get("NODE_TOKEN_PATH", "/data/node_token")
    enrollment_secret_path: str = os.environ.get("ENROLLMENT_SECRET_PATH", "/data/enrollment_secret")

    build_hash: str = os.environ.get("NODE_BUILD_HASH", "")
    tls_cert_fingerprint: str = os.environ.get("NODE_TLS_CERT_FINGERPRINT", "")
    release_signature: str = os.environ.get("NODE_RELEASE_SIGNATURE", "")

    signing_key_path: str = os.environ.get("NODE_SIGNING_KEY_PATH", "/data/node_signing_key")
    federation_nonce_db_path: str = os.environ.get("FEDERATION_NONCE_DB_PATH", "/data/federation_nonces.db")
    federation_audit_db_path: str = os.environ.get("FEDERATION_AUDIT_DB_PATH", "/data/federation_audit.db")
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")
    federation_envelope_mode: str = os.environ.get("FEDERATION_ENVELOPE_MODE", "legacy")

    media_node_url: str = os.environ.get("MEDIA_NODE_URL", "http://localhost:8004")
    media_access_secret: str = os.environ.get("MEDIA_ACCESS_SECRET", "") or os.environ.get(
        "JWT_SECRET", "dev-secret-change-me-in-production"
    )
    media_access_ttl_seconds: int = int(os.environ.get("MEDIA_ACCESS_TTL_SECONDS", "300"))

    # Bootstrap-phase registration/monitoring — see ADR-0006.
    capabilities: list = ["home"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")


settings = Settings()
