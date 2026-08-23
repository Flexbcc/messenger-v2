import os


class Settings:
    node_id: str = os.environ.get("MEDIA_NODE_ID", "media-local")
    public_url: str = os.environ.get("MEDIA_NODE_PUBLIC_URL", "http://localhost:8004")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")

    capabilities: list = ["media"]
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
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")

    jwt_secret: str = os.environ.get("JWT_SECRET", "dev-secret-change-me-in-production")
    media_access_secret: str = os.environ.get("MEDIA_ACCESS_SECRET", "") or os.environ.get(
        "JWT_SECRET", "dev-secret-change-me-in-production"
    )
    max_upload_bytes: int = int(os.environ.get("MEDIA_MAX_UPLOAD_BYTES", str(50 * 1024 * 1024)))


settings = Settings()
