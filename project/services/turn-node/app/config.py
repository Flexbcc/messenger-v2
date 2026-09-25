import os

from shared.security.outbound_tls import validated_service_origin


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
    node_id: str = os.environ.get("TURN_NODE_ID", "turn-local")
    public_url: str = validated_service_origin(
        os.environ.get("TURN_NODE_PUBLIC_URL", "http://localhost:8006"),
        "TURN_NODE_PUBLIC_URL",
    )
    discovery_url: str = validated_service_origin(
        os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        "DISCOVERY_NODE_URL",
    )

    capabilities: list = ["turn"]
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

    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "signed")
    jwt_secret: str = os.environ.get("JWT_SECRET", "")

    # The actual TURN server (coturn or equivalent — see spec/0605_TURN_NODE.md
    # → Назначение) this service issues credentials for. Not implemented by
    # this FastAPI app: RFC 8656 relaying is deliberately reused from an
    # existing implementation rather than written from scratch, same
    # rationale as libsignal for E2EE (ADR-0002). See README.md.
    turn_host: str = os.environ.get("TURN_SERVER_HOST", "localhost")
    turn_port: int = _bounded_int("TURN_SERVER_PORT", 3478, minimum=1, maximum=65535)
    turn_tls_port: int = _bounded_int("TURN_SERVER_TLS_PORT", 5349, minimum=1, maximum=65535)
    enable_udp: bool = _env_bool("TURN_ENABLE_UDP", True)
    enable_tcp: bool = _env_bool("TURN_ENABLE_TCP", True)
    enable_tls: bool = _env_bool("TURN_ENABLE_TLS", False)
    realm: str = os.environ.get("TURN_REALM", "messenger.local")

    # Shared secret with the TURN server's long-term REST credential
    # mechanism (coturn: `use-auth-secret` + `static-auth-secret`). The
    # The value is mandatory even in legacy mode: an embedded fallback would
    # make every unattended development deployment share one public key.
    shared_secret: str = os.environ.get("TURN_SHARED_SECRET", "")
    credential_ttl_seconds: int = _bounded_int(
        "TURN_CREDENTIAL_TTL_SECONDS", 600, minimum=60, maximum=3600
    )


settings = Settings()


def validate_turn_configuration() -> None:
    from shared.security.secret_validation import (
        require_configured_secret,
        require_independent_secrets,
    )

    if settings.internal_security_mode not in {"legacy", "signed"}:
        raise RuntimeError("INTERNAL_SECURITY_MODE must be legacy or signed")
    if not settings.enable_udp and not settings.enable_tcp and not settings.enable_tls:
        raise RuntimeError("at least one TURN transport must be enabled")
    if not settings.turn_host or any(character.isspace() for character in settings.turn_host):
        raise RuntimeError("TURN_SERVER_HOST is invalid")
    if not settings.realm or any(character.isspace() for character in settings.realm):
        raise RuntimeError("TURN_REALM is invalid")
    require_configured_secret("JWT_SECRET", settings.jwt_secret)
    require_configured_secret("TURN_SHARED_SECRET", settings.shared_secret)
    if settings.internal_security_mode == "signed":
        require_independent_secrets(
            {"JWT_SECRET": settings.jwt_secret, "TURN_SHARED_SECRET": settings.shared_secret}
        )
