import os


class Settings:
    node_id: str = os.environ.get("GATEWAY_NODE_ID", "gateway-local")
    public_url: str = os.environ.get("GATEWAY_NODE_PUBLIC_URL", "http://localhost:8007")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")
    discovery_public_url: str = os.environ.get(
        "GATEWAY_DISCOVERY_PUBLIC_URL",
        os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
    )
    default_home_url: str = os.environ.get("DEFAULT_HOME_NODE_URL", "http://localhost:8001")
    default_media_url: str = os.environ.get("DEFAULT_MEDIA_NODE_URL", "http://localhost:8004")

    capabilities: list = ["gateway"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")
    cluster_id: str = os.environ.get("CLUSTER_ID", "default")

    enrollment_mode: str = os.environ.get("ENROLLMENT_MODE", "legacy").lower()
    node_token_path: str = os.environ.get("NODE_TOKEN_PATH", "/data/node_token")
    enrollment_secret_path: str = os.environ.get("ENROLLMENT_SECRET_PATH", "/data/enrollment_secret")

    build_hash: str = os.environ.get("NODE_BUILD_HASH", "")
    tls_cert_fingerprint: str = os.environ.get("NODE_TLS_CERT_FINGERPRINT", "")
    release_signature: str = os.environ.get("NODE_RELEASE_SIGNATURE", "")


settings = Settings()
