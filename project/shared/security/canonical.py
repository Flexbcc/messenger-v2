import hashlib
import json
from typing import Any


def canonical_json(obj: Any) -> str:
    """Stable JSON for hashing — not used for wire envelope format."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def body_sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def signing_payload(
    *,
    node_id: str,
    timestamp: str,
    nonce: str,
    method: str,
    path: str,
    body: bytes,
) -> bytes:
    """Canonical federation signing string (ADR-0011)."""
    method_u = method.upper()
    path_norm = path if path.startswith("/") else f"/{path}"
    digest = body_sha256(body)
    return f"{node_id}|{timestamp}|{nonce}|{method_u}|{path_norm}|{digest}".encode()
