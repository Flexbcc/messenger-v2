"""mTLS policy helpers for Gateway (ADR-0010)."""
import hashlib
import hmac
import os
from pathlib import Path
from typing import Optional

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


GATEWAY_TLS_ENABLED = _env_bool("GATEWAY_TLS_ENABLED", True)
GATEWAY_TLS_CERT_PATH = os.environ.get("GATEWAY_TLS_CERT_PATH", "/mtls/gateway.crt")
GATEWAY_TLS_KEY_PATH = os.environ.get("GATEWAY_TLS_KEY_PATH", "/mtls/gateway.key")
GATEWAY_TLS_CLIENT_CA_PATH = os.environ.get("GATEWAY_TLS_CLIENT_CA_PATH", "/mtls/ca.crt")
try:
    GATEWAY_TLS_PORT = int(os.environ.get("GATEWAY_TLS_PORT", "8447"))
except ValueError as exc:
    raise RuntimeError("GATEWAY_TLS_PORT must be an integer") from exc
# off | optional | required — application-layer check via fingerprint header
GATEWAY_MTLS_MODE = os.environ.get("GATEWAY_MTLS_MODE", "required").lower()
GATEWAY_MTLS_PROXY_SECRET = os.environ.get("GATEWAY_MTLS_PROXY_SECRET", "")
ALLOW_INSECURE_GATEWAY_MTLS = _env_bool("ALLOW_INSECURE_GATEWAY_MTLS", False)
if GATEWAY_MTLS_MODE not in {"off", "optional", "required"}:
    raise RuntimeError("GATEWAY_MTLS_MODE must be off, optional, or required")
if not 1 <= GATEWAY_TLS_PORT <= 65535:
    raise RuntimeError("GATEWAY_TLS_PORT must be between 1 and 65535")
if GATEWAY_MTLS_MODE == "required" and not GATEWAY_TLS_ENABLED:
    raise RuntimeError("GATEWAY_MTLS_MODE=required requires GATEWAY_TLS_ENABLED=true")

ALLOWED_GATEWAY_CLIENT_FINGERPRINTS = frozenset(
    fp.strip().lower().replace("sha256:", "").replace(":", "")
    for fp in os.environ.get("ALLOWED_GATEWAY_CLIENT_FINGERPRINTS", "").split(",")
    if fp.strip()
)


def validate_mtls_configuration() -> None:
    if GATEWAY_MTLS_MODE != "required" and not ALLOW_INSECURE_GATEWAY_MTLS:
        raise RuntimeError(
            "Gateway mTLS downgrade requires ALLOW_INSECURE_GATEWAY_MTLS=true"
        )
    if GATEWAY_MTLS_MODE == "required" and not ALLOWED_GATEWAY_CLIENT_FINGERPRINTS:
        raise RuntimeError("ALLOWED_GATEWAY_CLIENT_FINGERPRINTS is required")
    if any(
        len(fingerprint) != 64
        or any(character not in "0123456789abcdef" for character in fingerprint)
        for fingerprint in ALLOWED_GATEWAY_CLIENT_FINGERPRINTS
    ):
        raise RuntimeError("Gateway client fingerprints must be SHA-256 hex")


def cert_sha256_fingerprint(pem_bytes: bytes) -> str:
    """Fingerprint of DER certificate bytes."""
    # PEM passed in — parse minimal between BEGIN/END
    if b"BEGIN CERTIFICATE" in pem_bytes:
        lines = []
        in_cert = False
        for line in pem_bytes.splitlines():
            if b"BEGIN CERTIFICATE" in line:
                in_cert = True
                continue
            if b"END CERTIFICATE" in line:
                break
            if in_cert:
                lines.append(line)
        import base64

        der = base64.b64decode(b"".join(lines))
    else:
        der = pem_bytes
    return hashlib.sha256(der).hexdigest()


def server_cert_fingerprint() -> Optional[str]:
    path = Path(GATEWAY_TLS_CERT_PATH)
    if not path.is_file():
        return None
    return cert_sha256_fingerprint(path.read_bytes())


def normalize_fingerprint(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    return value.lower().replace("sha256:", "").replace(":", "")


def client_fingerprint_allowed(fingerprint: Optional[str]) -> bool:
    fp = normalize_fingerprint(fingerprint)
    if not fp:
        return False
    return fp in ALLOWED_GATEWAY_CLIENT_FINGERPRINTS


def trusted_proxy(secret: Optional[str]) -> bool:
    return bool(
        secret
        and GATEWAY_MTLS_PROXY_SECRET
        and hmac.compare_digest(secret, GATEWAY_MTLS_PROXY_SECRET)
    )


def mtls_required_for_path(path: str) -> bool:
    if GATEWAY_MTLS_MODE != "required":
        return False
    if path in ("/health", "/gateway/mtls/info"):
        return False
    if path.startswith("/gateway/invite/redeem/"):
        return False
    if path == "/join":
        return False
    return path.startswith("/gateway/")
