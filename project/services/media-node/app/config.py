import os

from shared.security.outbound_tls import validated_service_origin


def _env_int(name: str, default: int, *, min_v: int, max_v: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError) as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not min_v <= value <= max_v:
        raise RuntimeError(f"{name} must be between {min_v} and {max_v}")
    return value


class Settings:
    node_id: str = os.environ.get("MEDIA_NODE_ID", "media-local")
    public_url: str = validated_service_origin(
        os.environ.get("MEDIA_NODE_PUBLIC_URL", "http://localhost:8004"),
        "MEDIA_NODE_PUBLIC_URL",
    )
    discovery_url: str = validated_service_origin(
        os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        "DISCOVERY_NODE_URL",
    )

    capabilities: list = ["media"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")
    cluster_id: str = os.environ.get("CLUSTER_ID", "default")

    enrollment_mode: str = os.environ.get("ENROLLMENT_MODE", "strict").lower()
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
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "signed")

    jwt_secret: str = os.environ.get("JWT_SECRET", "")
    media_access_secret: str = os.environ.get("MEDIA_ACCESS_SECRET", "")
    admin_secret: str = os.environ.get("MEDIA_ADMIN_SECRET", "")
    mesh_notify_secret: str = os.environ.get("MESH_NOTIFY_SECRET", "")
    home_db_backup_path: str = os.environ.get(
        "HOME_DB_BACKUP_PATH", "/data/home/home.db"
    )
    max_upload_bytes: int = _env_int(
        "MEDIA_MAX_UPLOAD_BYTES",
        50 * 1024 * 1024,
        min_v=1,
        max_v=1024 * 1024 * 1024,
    )
    home_storage_profile_cache_seconds: int = _env_int(
        "HOME_STORAGE_PROFILE_CACHE_SECONDS", 60, min_v=1, max_v=3600
    )


settings = Settings()


def validate_security_configuration() -> None:
    from shared.security.secret_validation import (
        require_configured_secret,
        require_independent_secrets,
        require_strong_secret,
    )

    require_configured_secret("JWT_SECRET", settings.jwt_secret)
    require_configured_secret("MEDIA_ACCESS_SECRET", settings.media_access_secret)
    require_strong_secret("MEDIA_ADMIN_SECRET", settings.admin_secret)
    require_strong_secret("MESH_NOTIFY_SECRET", settings.mesh_notify_secret)
    if settings.internal_security_mode != "signed":
        return

    require_independent_secrets(
        {
            "JWT_SECRET": settings.jwt_secret,
            "MEDIA_ACCESS_SECRET": settings.media_access_secret,
            "MEDIA_ADMIN_SECRET": settings.admin_secret,
            "MESH_NOTIFY_SECRET": settings.mesh_notify_secret,
        }
    )
