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
    node_id: str = os.environ.get("GATEWAY_NODE_ID", "gateway-local")
    public_url: str = validated_service_origin(
        os.environ.get("GATEWAY_NODE_PUBLIC_URL", "http://localhost:8007"),
        "GATEWAY_NODE_PUBLIC_URL",
    )
    discovery_url: str = validated_service_origin(
        os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        "DISCOVERY_NODE_URL",
    )
    discovery_public_url: str = validated_service_origin(
        os.environ.get(
            "GATEWAY_DISCOVERY_PUBLIC_URL",
            os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        ),
        "GATEWAY_DISCOVERY_PUBLIC_URL",
    )
    discovery_urls: tuple[str, ...] = tuple(
        dict.fromkeys(
            validated_service_origin(value.strip(), "GATEWAY_DISCOVERY_URLS")
            for value in os.environ.get(
                "GATEWAY_DISCOVERY_URLS",
                os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
            ).split(",")
            if value.strip()
        )
    )
    discovery_public_urls: tuple[str, ...] = tuple(
        dict.fromkeys(
            validated_service_origin(value.strip(), "GATEWAY_DISCOVERY_PUBLIC_URLS")
            for value in os.environ.get(
                "GATEWAY_DISCOVERY_PUBLIC_URLS",
                os.environ.get(
                    "GATEWAY_DISCOVERY_PUBLIC_URL",
                    os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
                ),
            ).split(",")
            if value.strip()
        )
    )
    capabilities: list = ["gateway"]
    software_version: str = os.environ.get("NODE_SOFTWARE_VERSION", "0.1.0")
    cluster_id: str = os.environ.get("CLUSTER_ID", "default")

    # One-time client join invites (QR). Empty = invite API disabled.
    invite_secret: str = os.environ.get("GATEWAY_INVITE_SECRET", "")
    mesh_notify_secret: str = os.environ.get("MESH_NOTIFY_SECRET", "")
    invite_db_path: str = os.environ.get("GATEWAY_INVITE_DB_PATH", "/data/invites.db")
    invite_ttl_seconds: int = _env_int(
        "GATEWAY_INVITE_TTL_SECONDS", 300, min_v=30, max_v=86400
    )

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


settings = Settings()

if not settings.discovery_urls:
    raise RuntimeError("GATEWAY_DISCOVERY_URLS must contain at least one origin")
if not settings.discovery_public_urls:
    raise RuntimeError(
        "GATEWAY_DISCOVERY_PUBLIC_URLS must contain at least one origin"
    )


def validate_security_configuration() -> None:
    from shared.security.config import INTERNAL_SECURITY_MODE
    from shared.security.secret_validation import (
        require_independent_secrets,
        require_strong_secret,
    )
    from app.mtls import (
        GATEWAY_MTLS_MODE,
        GATEWAY_MTLS_PROXY_SECRET,
        validate_mtls_configuration,
    )

    validate_mtls_configuration()
    require_strong_secret("MESH_NOTIFY_SECRET", settings.mesh_notify_secret)
    if GATEWAY_MTLS_MODE == "required":
        require_strong_secret(
            "GATEWAY_MTLS_PROXY_SECRET", GATEWAY_MTLS_PROXY_SECRET
        )

    if INTERNAL_SECURITY_MODE == "signed":
        require_strong_secret("GATEWAY_INVITE_SECRET", settings.invite_secret)
    configured_secrets = {"MESH_NOTIFY_SECRET": settings.mesh_notify_secret}
    if settings.invite_secret:
        configured_secrets["GATEWAY_INVITE_SECRET"] = settings.invite_secret
    if GATEWAY_MTLS_PROXY_SECRET:
        configured_secrets["GATEWAY_MTLS_PROXY_SECRET"] = GATEWAY_MTLS_PROXY_SECRET
    require_independent_secrets(configured_secrets)
