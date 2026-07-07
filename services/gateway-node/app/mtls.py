"""mTLS policy helpers for Gateway (ADR-0010)."""
import hashlib
import os
from pathlib import Path
from typing import Optional

GATEWAY_TLS_ENABLED = os.environ.get("GATEWAY_TLS_ENABLED", "false").lower() == "true"
GATEWAY_TLS_CERT_PATH = os.environ.get("GATEWAY_TLS_CERT_PATH", "/mtls/gateway.crt")
GATEWAY_TLS_KEY_PATH = os.environ.get("GATEWAY_TLS_KEY_PATH", "/mtls/gateway.key")
GATEWAY_TLS_CLIENT_CA_PATH = os.environ.get("GATEWAY_TLS_CLIENT_CA_PATH", "/mtls/ca.crt")
GATEWAY_TLS_PORT = int(os.environ.get("GATEWAY_TLS_PORT", "8447"))
# off | optional | required — application-layer check via fingerprint header
GATEWAY_MTLS_MODE = os.environ.get("GATEWAY_MTLS_MODE", "off").lower()

ALLOWED_GATEWAY_CLIENT_FINGERPRINTS = frozenset(
    fp.strip().lower()
    for fp in os.environ.get("ALLOWED_GATEWAY_CLIENT_FINGERPRINTS", "").split(",")
    if fp.strip()
)


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
    if not ALLOWED_GATEWAY_CLIENT_FINGERPRINTS:
        return True
    return fp in ALLOWED_GATEWAY_CLIENT_FINGERPRINTS


def mtls_required_for_path(path: str) -> bool:
    if GATEWAY_MTLS_MODE != "required":
        return False
    if path in ("/health", "/gateway/mtls/info"):
        return False
    return path.startswith("/gateway/")
