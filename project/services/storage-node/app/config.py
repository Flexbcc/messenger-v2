import os

from shared.security.outbound_tls import validated_service_origin
from shared.security.user_home_record import parse_discovery_signing_public_keys


def _bounded_int(name: str, default: int, *, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")
    return value


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


class Settings:
    advertise_to_network: bool = _env_bool("NODE_PARTICIPATE_STORAGE", True)
    node_id: str = os.environ.get("STORAGE_NODE_ID", "storage-local")
    public_url: str = validated_service_origin(
        os.environ.get("STORAGE_NODE_PUBLIC_URL", "http://localhost:8002"),
        "STORAGE_NODE_PUBLIC_URL",
    )
    discovery_url: str = validated_service_origin(
        os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        "DISCOVERY_NODE_URL",
    )
    discovery_signing_public_keys: frozenset[str] = parse_discovery_signing_public_keys(
        os.environ.get("DISCOVERY_SIGNING_PUBLIC_KEYS", "")
    )

    capabilities: list = ["storage"] if advertise_to_network else []
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
    federation_audit_db_path: str = os.environ.get("FEDERATION_AUDIT_DB_PATH", "/data/federation_audit.db")
    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "signed")
    max_opaque_storage_bytes: int = _bounded_int(
        "STORAGE_MAX_OPAQUE_BYTES",
        2 * 1024 * 1024 * 1024,
        minimum=4 * 1024,
        maximum=1024 * 1024 * 1024 * 1024,
    )
    max_padded_poll_bytes: int = _bounded_int(
        "STORAGE_MAX_PADDED_POLL_BYTES",
        1024 * 1024,
        minimum=4 * 1024,
        maximum=8 * 1024 * 1024,
    )


settings = Settings()


def validate_security_configuration() -> None:
    allow_insecure_lab = os.environ.get(
        "ALLOW_INSECURE_STORAGE_MODE", "false"
    ).strip().lower() in {"1", "true", "yes", "on"}
    if settings.internal_security_mode != "signed" and not allow_insecure_lab:
        raise RuntimeError("Storage Node requires INTERNAL_SECURITY_MODE=signed")
    if settings.internal_security_mode == "signed" and not settings.discovery_signing_public_keys:
        raise RuntimeError("DISCOVERY_SIGNING_PUBLIC_KEYS is required")
