"""OUO Node Identity v1 reference primitives.

This module deliberately does not integrate with Discovery yet.  It defines
the self-certifying NodeID and root-signed short-lived operational certificate
used by the migration described in spec/0206_NODE_IDENTITY.md.
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


PROTOCOL_VERSION = "ouo-node-identity/1"
OBJECT_VERSION = 1
SIGNATURE_ALGORITHM = "Ed25519"
NODE_ID_PREFIX = "ouo-node-v1-"
MAX_CERTIFICATE_LIFETIME = timedelta(days=7)
DEFAULT_CLOCK_SKEW = timedelta(minutes=5)
SIGNING_DOMAIN = b"OUO/NODE_OPERATIONAL_CERT/v1\x00"

_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "node_id",
    "root_public_key",
    "operational_public_key",
    "serial",
    "issued_at",
    "valid_until",
    "signature_algorithm",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class CertificateValidation:
    valid: bool
    reason: Optional[str] = None


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii")


def _b64decode(value: str) -> bytes:
    return base64.b64decode(value.encode("ascii"), altchars=b"-_", validate=True)


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


def node_id_from_root_public_key(root_public_key: bytes) -> str:
    """Return the full SHA-256 based, self-certifying NodeID."""
    if len(root_public_key) != 32:
        raise ValueError("Ed25519 root public key must be 32 bytes")
    digest = hashlib.sha256(root_public_key).digest()
    encoded = base64.b32encode(digest).decode("ascii").rstrip("=").lower()
    return NODE_ID_PREFIX + encoded


def certificate_signing_payload(certificate: Mapping[str, Any]) -> bytes:
    unsigned = {key: certificate[key] for key in _UNSIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(unsigned).encode("utf-8")


def issue_operational_certificate(
    *,
    root_signing_key: SigningKey,
    operational_verify_key: VerifyKey,
    issued_at: datetime,
    valid_until: datetime,
    serial: Optional[str] = None,
) -> dict[str, Any]:
    """Issue a v1 operational certificate signed by the Node Root key."""
    issued_at_text = _utc_iso(issued_at)
    valid_until_text = _utc_iso(valid_until)
    lifetime = valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc)
    if lifetime <= timedelta(0):
        raise ValueError("valid_until must be later than issued_at")
    if lifetime > MAX_CERTIFICATE_LIFETIME:
        raise ValueError("operational certificate lifetime exceeds 7 days")

    serial_value = serial or str(uuid.uuid4())
    try:
        parsed_serial = uuid.UUID(serial_value)
    except (AttributeError, TypeError, ValueError) as exc:
        raise ValueError("serial must be a canonical UUID string") from exc
    if str(parsed_serial) != serial_value:
        raise ValueError("serial must be a canonical UUID string")

    root_public_key = bytes(root_signing_key.verify_key)
    certificate: dict[str, Any] = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "node_id": node_id_from_root_public_key(root_public_key),
        "root_public_key": _b64encode(root_public_key),
        "operational_public_key": _b64encode(bytes(operational_verify_key)),
        "serial": serial_value,
        "issued_at": issued_at_text,
        "valid_until": valid_until_text,
        "signature_algorithm": SIGNATURE_ALGORITHM,
    }
    certificate["signature"] = sign_message(
        root_signing_key, certificate_signing_payload(certificate)
    )
    return certificate


def validate_operational_certificate(
    certificate: Mapping[str, Any],
    *,
    now: datetime,
    clock_skew: timedelta = DEFAULT_CLOCK_SKEW,
) -> CertificateValidation:
    """Validate structure, self-certifying identity, lifetime and signature."""
    if not isinstance(certificate, Mapping):
        return CertificateValidation(False, "certificate must be an object")
    if set(certificate) != _ALL_FIELDS:
        return CertificateValidation(False, "invalid certificate fields")
    if certificate.get("protocol_version") != PROTOCOL_VERSION:
        return CertificateValidation(False, "unsupported protocol_version")
    if certificate.get("object_version") != OBJECT_VERSION:
        return CertificateValidation(False, "unsupported object_version")
    if certificate.get("signature_algorithm") != SIGNATURE_ALGORITHM:
        return CertificateValidation(False, "unsupported signature_algorithm")
    if now.tzinfo is None or now.utcoffset() is None:
        return CertificateValidation(False, "validation time must be timezone-aware")
    if clock_skew < timedelta(0):
        return CertificateValidation(False, "clock_skew cannot be negative")

    try:
        serial_value = certificate["serial"]
        if not isinstance(serial_value, str) or str(uuid.UUID(serial_value)) != serial_value:
            return CertificateValidation(False, "invalid certificate serial")
        root_public_key = _b64decode(str(certificate["root_public_key"]))
        operational_public_key = _b64decode(str(certificate["operational_public_key"]))
        if len(root_public_key) != 32 or len(operational_public_key) != 32:
            return CertificateValidation(False, "invalid public key length")
        expected_node_id = node_id_from_root_public_key(root_public_key)
        if certificate["node_id"] != expected_node_id:
            return CertificateValidation(False, "node_id does not match root public key")
        issued_at = _parse_utc(certificate["issued_at"])
        valid_until = _parse_utc(certificate["valid_until"])
    except (KeyError, TypeError, ValueError):
        return CertificateValidation(False, "malformed certificate")

    lifetime = valid_until - issued_at
    if lifetime <= timedelta(0):
        return CertificateValidation(False, "invalid certificate lifetime")
    if lifetime > MAX_CERTIFICATE_LIFETIME:
        return CertificateValidation(False, "certificate lifetime exceeds 7 days")

    now_utc = now.astimezone(timezone.utc)
    if now_utc + clock_skew < issued_at:
        return CertificateValidation(False, "certificate is not yet valid")
    if now_utc - clock_skew > valid_until:
        return CertificateValidation(False, "certificate has expired")

    if not verify_message(
        str(certificate["root_public_key"]),
        certificate_signing_payload(certificate),
        str(certificate["signature"]),
    ):
        return CertificateValidation(False, "invalid root signature")
    return CertificateValidation(True)
