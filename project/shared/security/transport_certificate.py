"""Root-signed, short-lived transport/KEM credential for onion routing."""

from __future__ import annotations

import base64
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.public import PrivateKey
from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import node_id_from_root_public_key


PROTOCOL_VERSION = "ouo-node-transport-certificate/1"
OBJECT_VERSION = 1
KEM_ALGORITHM = "X25519"
KEY_USAGE = "OUO/SPHINX_TRANSPORT"
MAX_LIFETIME = timedelta(days=7)
CLOCK_SKEW = timedelta(minutes=5)
SIGNING_DOMAIN = b"OUO/NODE_TRANSPORT_CERT/v1\x00"
UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "node_id",
    "root_public_key",
    "transport_public_key",
    "kem_algorithm",
    "key_usage",
    "serial",
    "issued_at",
    "valid_until",
}
ALL_FIELDS = UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class TransportCertificateValidation:
    valid: bool
    reason: str | None = None


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii")


def _decode(value: Any) -> bytes:
    if not isinstance(value, str):
        raise ValueError("public key must be a string")
    return base64.b64decode(value.encode("ascii"), altchars=b"-_", validate=True)


def _iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def signing_payload(certificate: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: certificate[field] for field in UNSIGNED_FIELDS}
    ).encode("utf-8")


def issue_transport_certificate(
    *,
    root_signing_key: SigningKey,
    transport_private_key: PrivateKey,
    issued_at: datetime,
    valid_until: datetime,
    serial: str | None = None,
) -> dict[str, Any]:
    if issued_at.tzinfo is None or issued_at.utcoffset() is None:
        raise ValueError("issued_at must be timezone-aware")
    if valid_until.tzinfo is None or valid_until.utcoffset() is None:
        raise ValueError("valid_until must be timezone-aware")
    lifetime = valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc)
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        raise ValueError("invalid transport certificate lifetime")
    serial_value = serial or str(uuid.uuid4())
    if str(uuid.UUID(serial_value)) != serial_value:
        raise ValueError("serial must be a canonical UUID")
    root_public = bytes(root_signing_key.verify_key)
    certificate = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "node_id": node_id_from_root_public_key(root_public),
        "root_public_key": _b64(root_public),
        "transport_public_key": _b64(bytes(transport_private_key.public_key)),
        "kem_algorithm": KEM_ALGORITHM,
        "key_usage": KEY_USAGE,
        "serial": serial_value,
        "issued_at": _iso(issued_at),
        "valid_until": _iso(valid_until),
    }
    certificate["signature"] = sign_message(root_signing_key, signing_payload(certificate))
    return certificate


def validate_transport_certificate(
    certificate: Mapping[str, Any], *, now: datetime, expected_node_id: str | None = None
) -> TransportCertificateValidation:
    if not isinstance(certificate, Mapping) or set(certificate) != ALL_FIELDS:
        return TransportCertificateValidation(False, "invalid transport certificate fields")
    if certificate.get("protocol_version") != PROTOCOL_VERSION:
        return TransportCertificateValidation(False, "unsupported protocol_version")
    if certificate.get("object_version") != OBJECT_VERSION:
        return TransportCertificateValidation(False, "unsupported object_version")
    if certificate.get("kem_algorithm") != KEM_ALGORITHM or certificate.get("key_usage") != KEY_USAGE:
        return TransportCertificateValidation(False, "unsupported transport key parameters")
    if now.tzinfo is None or now.utcoffset() is None:
        return TransportCertificateValidation(False, "validation time must be timezone-aware")
    try:
        if str(uuid.UUID(certificate["serial"])) != certificate["serial"]:
            return TransportCertificateValidation(False, "invalid certificate serial")
        root_public = _decode(certificate["root_public_key"])
        transport_public = _decode(certificate["transport_public_key"])
        if len(root_public) != 32 or len(transport_public) != 32:
            return TransportCertificateValidation(False, "invalid public key length")
        node_id = node_id_from_root_public_key(root_public)
        issued_at = _time(certificate["issued_at"])
        valid_until = _time(certificate["valid_until"])
    except (KeyError, TypeError, ValueError):
        return TransportCertificateValidation(False, "malformed transport certificate")
    if certificate.get("node_id") != node_id or (expected_node_id and node_id != expected_node_id):
        return TransportCertificateValidation(False, "transport certificate NodeID mismatch")
    lifetime = valid_until - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return TransportCertificateValidation(False, "invalid transport certificate lifetime")
    current = now.astimezone(timezone.utc)
    if current + CLOCK_SKEW < issued_at:
        return TransportCertificateValidation(False, "transport certificate is not yet valid")
    if current - CLOCK_SKEW > valid_until:
        return TransportCertificateValidation(False, "transport certificate expired")
    if not isinstance(certificate.get("signature"), str) or not verify_message(
        certificate["root_public_key"], signing_payload(certificate), certificate["signature"]
    ):
        return TransportCertificateValidation(False, "invalid root signature")
    return TransportCertificateValidation(True)
