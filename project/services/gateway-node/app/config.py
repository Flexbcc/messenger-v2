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

    # One-time client join invites (QR). Empty = invite API disabled.
    invite_secret: str = os.environ.get("GATEWAY_INVITE_SECRET", "")
    invite_db_path: str = os.environ.get("GATEWAY_INVITE_DB_PATH", "/data/invites.db")
    invite_ttl_seconds: int = int(os.environ.get("GATEWAY_INVITE_TTL_SECONDS", "300"))

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


settings = Settings()
