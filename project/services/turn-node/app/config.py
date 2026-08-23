import hmac
import os


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
    return default if raw is None else raw.strip().lower() in {"1", "true", "yes", "on"}


class Settings:
    node_id: str = os.environ.get("TURN_NODE_ID", "turn-local")
    public_url: str = os.environ.get("TURN_NODE_PUBLIC_URL", "http://localhost:8006")
    discovery_url: str = os.environ.get("DISCOVERY_NODE_URL", "http://localhost:8003")

    capabilities: list = ["turn"]
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

    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")
    jwt_secret: str = os.environ.get("JWT_SECRET", "dev-secret-change-me-in-production")

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
    # default is a fixed dev-only value — any real deployment MUST override
    # this via env (see spec/0605_TURN_NODE.md → Ограничения).
    shared_secret: str = os.environ.get("TURN_SHARED_SECRET", "dev-only-insecure-secret-change-me")
    credential_ttl_seconds: int = _bounded_int(
        "TURN_CREDENTIAL_TTL_SECONDS", 600, minimum=60, maximum=3600
    )


settings = Settings()


def validate_turn_configuration() -> None:
    if not settings.enable_udp and not settings.enable_tcp and not settings.enable_tls:
        raise RuntimeError("at least one TURN transport must be enabled")
    if not settings.turn_host or any(character.isspace() for character in settings.turn_host):
        raise RuntimeError("TURN_SERVER_HOST is invalid")
    if not settings.realm or any(character.isspace() for character in settings.realm):
        raise RuntimeError("TURN_REALM is invalid")
    if settings.internal_security_mode not in {"legacy", "off", ""}:
        if settings.shared_secret == "dev-only-insecure-secret-change-me":
            raise RuntimeError("secure TURN requires a non-development shared secret")
        if settings.jwt_secret == "dev-secret-change-me-in-production":
            raise RuntimeError("secure TURN requires a non-development JWT secret")
        if hmac.compare_digest(settings.shared_secret, settings.jwt_secret):
            raise RuntimeError("TURN shared secret and JWT secret must be separated")
