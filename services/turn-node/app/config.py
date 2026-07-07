import os


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

    internal_security_mode: str = os.environ.get("INTERNAL_SECURITY_MODE", "legacy")
    jwt_secret: str = os.environ.get("JWT_SECRET", "dev-secret-change-me-in-production")

    # The actual TURN server (coturn or equivalent — see spec/0605_TURN_NODE.md
    # → Назначение) this service issues credentials for. Not implemented by
    # this FastAPI app: RFC 8656 relaying is deliberately reused from an
    # existing implementation rather than written from scratch, same
    # rationale as libsignal for E2EE (ADR-0002). See README.md.
    turn_host: str = os.environ.get("TURN_SERVER_HOST", "localhost")
    turn_port: int = int(os.environ.get("TURN_SERVER_PORT", "3478"))

    # Shared secret with the TURN server's long-term REST credential
    # mechanism (coturn: `use-auth-secret` + `static-auth-secret`). The
    # default is a fixed dev-only value — any real deployment MUST override
    # this via env (see spec/0605_TURN_NODE.md → Ограничения).
    shared_secret: str = os.environ.get("TURN_SHARED_SECRET", "dev-only-insecure-secret-change-me")
    credential_ttl_seconds: int = int(os.environ.get("TURN_CREDENTIAL_TTL_SECONDS", "600"))


settings = Settings()
