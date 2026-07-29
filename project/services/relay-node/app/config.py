import os


class Settings:
    node_id: str = os.environ.get("RELAY_NODE_ID", "relay-local")
    public_url: str = os.environ.get("RELAY_NODE_PUBLIC_URL", "http://localhost:8005")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")

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
    federation_nonce_db_path: str = os.environ.get("FEDERATION_NONCE_DB_PATH", "/data/federation_nonces.db")
    federation_audit_db_path: str = os.environ.get("FEDERATION_AUDIT_DB_PATH", "/data/federation_audit.db")
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")

    # Rate-limit транзитных сообщений (Фаза 3.2)
    # Максимум запросов от одного origin_node_id за окно RELAY_RATE_WINDOW_SECONDS.
    relay_rate_limit: int = int(os.environ.get("RELAY_RATE_LIMIT", "100"))
    relay_rate_window_seconds: int = int(os.environ.get("RELAY_RATE_WINDOW_SECONDS", "60"))


settings = Settings()
