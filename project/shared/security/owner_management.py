"""Cryptographic primitives for headless node-owner management.

The module deliberately contains no HTTP or persistence code.  It defines the
portable objects shared by a node, CLI and mobile client: a node-root-signed
owner-device certificate and a device-signed management request.
"""

import base64
import hashlib
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional

from nacl.signing import SigningKey, VerifyKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import node_id_from_root_public_key


CERTIFICATE_PROTOCOL = "ouo-owner-device/1"
REQUEST_PROTOCOL = "ouo-owner-request/1"
OBJECT_VERSION = 1
SIGNATURE_ALGORITHM = "Ed25519"
MAX_CERTIFICATE_LIFETIME = timedelta(days=90)
MAX_REQUEST_AGE = timedelta(minutes=2)
DEFAULT_CLOCK_SKEW = timedelta(seconds=30)
ALLOWED_ROLES = frozenset({"viewer", "operator", "owner"})

_CERTIFICATE_DOMAIN = b"OUO/OWNER_DEVICE_CERT/v1\x00"
_REQUEST_DOMAIN = b"OUO/OWNER_REQUEST/v1\x00"
_CERTIFICATE_FIELDS = {
    "protocol_version",
    "object_version",
    "node_id",
    "node_root_public_key",
    "device_id",
    "device_public_key",
    "role",
    "serial",
    "issued_at",
    "valid_until",
    "signature_algorithm",
    "signature",
}
_REQUEST_FIELDS = {
    "protocol_version",
    "object_version",
    "certificate_serial",
    "timestamp",
    "nonce",
    "sequence",
    "method",
    "path",
    "body_sha256",
    "signature_algorithm",
    "signature",
}


@dataclass(frozen=True)
class OwnerValidation:
    valid: bool
    reason: Optional[str] = None


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_utc(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _verify_key_b64(verify_key: VerifyKey) -> str:
    return base64.urlsafe_b64encode(bytes(verify_key)).decode("ascii")


def _certificate_payload(certificate: Mapping[str, Any]) -> bytes:
    unsigned = {key: certificate[key] for key in _CERTIFICATE_FIELDS - {"signature"}}
    return _CERTIFICATE_DOMAIN + canonical_json(unsigned).encode("utf-8")


def _request_payload(request: Mapping[str, Any]) -> bytes:
    unsigned = {key: request[key] for key in _REQUEST_FIELDS - {"signature"}}
    return _REQUEST_DOMAIN + canonical_json(unsigned).encode("utf-8")


def issue_owner_device_certificate(
    *,
    node_root_signing_key: SigningKey,
    device_verify_key: VerifyKey,
    role: str,
    issued_at: datetime,
    valid_until: datetime,
    device_id: Optional[str] = None,
    serial: Optional[str] = None,
) -> dict[str, Any]:
    """Bind one device key and least-privilege role to a specific node."""
    if role not in ALLOWED_ROLES:
        raise ValueError("unsupported owner role")
    lifetime = valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc)
    if lifetime <= timedelta(0) or lifetime > MAX_CERTIFICATE_LIFETIME:
        raise ValueError("invalid owner certificate lifetime")

    device_id_value = device_id or str(uuid.uuid4())
    serial_value = serial or str(uuid.uuid4())
    for name, value in (("device_id", device_id_value), ("serial", serial_value)):
        if str(uuid.UUID(value)) != value:
            raise ValueError(f"{name} must be a canonical UUID string")

    root_public_key = bytes(node_root_signing_key.verify_key)
    certificate: dict[str, Any] = {
        "protocol_version": CERTIFICATE_PROTOCOL,
        "object_version": OBJECT_VERSION,
        "node_id": node_id_from_root_public_key(root_public_key),
        "node_root_public_key": base64.urlsafe_b64encode(root_public_key).decode(
            "ascii"
        ),
        "device_id": device_id_value,
        "device_public_key": _verify_key_b64(device_verify_key),
        "role": role,
        "serial": serial_value,
        "issued_at": _utc_iso(issued_at),
        "valid_until": _utc_iso(valid_until),
        "signature_algorithm": SIGNATURE_ALGORITHM,
    }
    certificate["signature"] = sign_message(
        node_root_signing_key, _certificate_payload(certificate)
    )
    return certificate


def validate_owner_device_certificate(
    certificate: Mapping[str, Any],
    *,
    node_root_public_key: str,
    now: datetime,
    revoked_serials: frozenset[str] = frozenset(),
) -> OwnerValidation:
    if not isinstance(certificate, Mapping) or set(certificate) != _CERTIFICATE_FIELDS:
        return OwnerValidation(False, "invalid certificate fields")
    if certificate.get("protocol_version") != CERTIFICATE_PROTOCOL:
        return OwnerValidation(False, "unsupported certificate protocol")
    if certificate.get("object_version") != OBJECT_VERSION:
        return OwnerValidation(False, "unsupported certificate version")
    if certificate.get("signature_algorithm") != SIGNATURE_ALGORITHM:
        return OwnerValidation(False, "unsupported signature algorithm")
    if certificate.get("role") not in ALLOWED_ROLES:
        return OwnerValidation(False, "unsupported owner role")
    if certificate.get("serial") in revoked_serials:
        return OwnerValidation(False, "certificate revoked")
    try:
        if str(uuid.UUID(str(certificate["device_id"]))) != certificate["device_id"]:
            return OwnerValidation(False, "invalid device_id")
        if str(uuid.UUID(str(certificate["serial"]))) != certificate["serial"]:
            return OwnerValidation(False, "invalid serial")
        issued_at = _parse_utc(certificate["issued_at"])
        valid_until = _parse_utc(certificate["valid_until"])
        embedded_root_public_key = str(certificate["node_root_public_key"])
        if not secrets_compare(embedded_root_public_key, node_root_public_key):
            return OwnerValidation(False, "certificate root key mismatch")
        expected_node_id = node_id_from_root_public_key(
            base64.b64decode(embedded_root_public_key, altchars=b"-_", validate=True)
        )
    except (KeyError, TypeError, ValueError):
        return OwnerValidation(False, "malformed certificate")
    if certificate["node_id"] != expected_node_id:
        return OwnerValidation(False, "certificate belongs to another node")
    if valid_until - issued_at <= timedelta(0) or valid_until - issued_at > MAX_CERTIFICATE_LIFETIME:
        return OwnerValidation(False, "invalid certificate lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc < issued_at or now_utc > valid_until:
        return OwnerValidation(False, "certificate is not currently valid")
    if not verify_message(node_root_public_key, _certificate_payload(certificate), str(certificate["signature"])):
        return OwnerValidation(False, "invalid certificate signature")
    return OwnerValidation(True)


def secrets_compare(first: str, second: str) -> bool:
    """Constant-time comparison without accepting non-string coercion."""
    import secrets

    return isinstance(first, str) and isinstance(second, str) and secrets.compare_digest(first, second)


def sign_owner_request(
    *,
    device_signing_key: SigningKey,
    certificate_serial: str,
    timestamp: datetime,
    nonce: str,
    sequence: int,
    method: str,
    path: str,
    body: bytes,
) -> dict[str, Any]:
    if sequence < 0:
        raise ValueError("sequence cannot be negative")
    if not nonce or len(nonce) > 128:
        raise ValueError("nonce must contain 1..128 characters")
    request: dict[str, Any] = {
        "protocol_version": REQUEST_PROTOCOL,
        "object_version": OBJECT_VERSION,
        "certificate_serial": certificate_serial,
        "timestamp": _utc_iso(timestamp),
        "nonce": nonce,
        "sequence": sequence,
        "method": method.upper(),
        "path": path if path.startswith("/") else f"/{path}",
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "signature_algorithm": SIGNATURE_ALGORITHM,
    }
    request["signature"] = sign_message(device_signing_key, _request_payload(request))
    return request


def validate_owner_request(
    request: Mapping[str, Any],
    *,
    certificate: Mapping[str, Any],
    now: datetime,
    method: str,
    path: str,
    body: bytes,
    minimum_sequence: int,
    seen_nonces: frozenset[str] = frozenset(),
) -> OwnerValidation:
    """Validate request binding; caller persists sequence and nonce on success."""
    if not isinstance(request, Mapping) or set(request) != _REQUEST_FIELDS:
        return OwnerValidation(False, "invalid request fields")
    if request.get("protocol_version") != REQUEST_PROTOCOL or request.get("object_version") != OBJECT_VERSION:
        return OwnerValidation(False, "unsupported request version")
    if request.get("signature_algorithm") != SIGNATURE_ALGORITHM:
        return OwnerValidation(False, "unsupported signature algorithm")
    if request.get("certificate_serial") != certificate.get("serial"):
        return OwnerValidation(False, "certificate serial mismatch")
    if request.get("nonce") in seen_nonces:
        return OwnerValidation(False, "request nonce already used")
    if not isinstance(request.get("sequence"), int) or request["sequence"] < minimum_sequence:
        return OwnerValidation(False, "request sequence is stale")
    expected_path = path if path.startswith("/") else f"/{path}"
    if request.get("method") != method.upper() or request.get("path") != expected_path:
        return OwnerValidation(False, "request target mismatch")
    if request.get("body_sha256") != hashlib.sha256(body).hexdigest():
        return OwnerValidation(False, "request body mismatch")
    try:
        timestamp = _parse_utc(request["timestamp"])
    except (KeyError, TypeError, ValueError):
        return OwnerValidation(False, "invalid request timestamp")
    age = now.astimezone(timezone.utc) - timestamp
    if age > MAX_REQUEST_AGE or age < -DEFAULT_CLOCK_SKEW:
        return OwnerValidation(False, "request timestamp outside allowed window")
    if not verify_message(
        str(certificate.get("device_public_key", "")),
        _request_payload(request),
        str(request.get("signature", "")),
    ):
        return OwnerValidation(False, "invalid request signature")
    return OwnerValidation(True)
