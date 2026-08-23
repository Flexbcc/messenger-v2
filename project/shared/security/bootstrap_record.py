"""User-signed BootstrapRecord v1 distributed by untrusted Discovery nodes."""

import base64
import hashlib
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import urlsplit

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import public_key_b64, sign_message, verify_message


PROTOCOL_VERSION = "ouo-bootstrap-record/1"
OBJECT_VERSION = 1
USER_ID_PREFIX = "ouo-user-v1-"
SIGNING_DOMAIN = b"OUO/BOOTSTRAP_RECORD/v1\x00"
MAX_LIFETIME = timedelta(hours=24)
CLOCK_SKEW = timedelta(minutes=5)
_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "record_id",
    "user_id",
    "identity_public_key",
    "identity_version",
    "rendezvous_data",
    "record_version",
    "issued_at",
    "expires_at",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class BootstrapRecordValidation:
    valid: bool
    reason: Optional[str] = None


def user_id_from_identity_public_key(identity_public_key: bytes) -> str:
    if len(identity_public_key) != 32:
        raise ValueError("Ed25519 identity public key must be 32 bytes")
    digest = hashlib.sha256(identity_public_key).digest()
    return USER_ID_PREFIX + base64.b32encode(digest).decode("ascii").rstrip("=").lower()


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def bootstrap_record_signing_payload(record: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: record[field] for field in _UNSIGNED_FIELDS}
    ).encode("utf-8")


def issue_bootstrap_record(
    *,
    identity_signing_key: SigningKey,
    identity_version: int,
    ingress_endpoints: Sequence[str],
    record_version: int,
    issued_at: datetime,
    expires_at: datetime,
    record_id: Optional[str] = None,
) -> dict[str, Any]:
    identity_public_key = bytes(identity_signing_key.verify_key)
    record = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "record_id": record_id or str(uuid.uuid4()),
        "user_id": user_id_from_identity_public_key(identity_public_key),
        "identity_public_key": public_key_b64(identity_signing_key),
        "identity_version": identity_version,
        "rendezvous_data": {"ingress_endpoints": sorted(ingress_endpoints)},
        "record_version": record_version,
        "issued_at": _utc_iso(issued_at),
        "expires_at": _utc_iso(expires_at),
    }
    record["signature"] = sign_message(
        identity_signing_key, bootstrap_record_signing_payload(record)
    )
    return record


def _valid_endpoint(endpoint: Any) -> bool:
    if not isinstance(endpoint, str) or not endpoint or len(endpoint) > 2048:
        return False
    parsed = urlsplit(endpoint)
    return bool(
        parsed.scheme in {"https", "wss"}
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def validate_bootstrap_record(
    record: Mapping[str, Any],
    *,
    now: datetime,
    minimum_identity_version: int = 1,
    minimum_record_version: int = 1,
) -> BootstrapRecordValidation:
    if not isinstance(record, Mapping) or set(record) != _ALL_FIELDS:
        return BootstrapRecordValidation(False, "invalid record fields")
    if record.get("protocol_version") != PROTOCOL_VERSION:
        return BootstrapRecordValidation(False, "unsupported protocol_version")
    if record.get("object_version") != OBJECT_VERSION:
        return BootstrapRecordValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(record["record_id"])) != record["record_id"]:
            return BootstrapRecordValidation(False, "invalid record_id")
    except (AttributeError, TypeError, ValueError):
        return BootstrapRecordValidation(False, "invalid record_id")
    identity_version = record.get("identity_version")
    record_version = record.get("record_version")
    if (
        not isinstance(identity_version, int)
        or isinstance(identity_version, bool)
        or identity_version < minimum_identity_version
    ):
        return BootstrapRecordValidation(False, "invalid or stale identity_version")
    if (
        not isinstance(record_version, int)
        or isinstance(record_version, bool)
        or record_version < minimum_record_version
    ):
        return BootstrapRecordValidation(False, "invalid or stale record_version")
    rendezvous = record.get("rendezvous_data")
    if not isinstance(rendezvous, Mapping) or set(rendezvous) != {"ingress_endpoints"}:
        return BootstrapRecordValidation(False, "invalid rendezvous_data")
    endpoints = rendezvous.get("ingress_endpoints")
    if (
        not isinstance(endpoints, list)
        or not endpoints
        or len(endpoints) > 8
        or endpoints != sorted(set(endpoints))
        or any(not _valid_endpoint(endpoint) for endpoint in endpoints)
    ):
        return BootstrapRecordValidation(False, "invalid ingress_endpoints")
    if now.tzinfo is None or now.utcoffset() is None:
        return BootstrapRecordValidation(False, "validation time must be timezone-aware")
    try:
        public_key_text = record["identity_public_key"]
        public_key = base64.b64decode(
            public_key_text.encode("ascii"), altchars=b"-_", validate=True
        )
        if len(public_key) != 32:
            return BootstrapRecordValidation(False, "invalid identity public key")
        if record["user_id"] != user_id_from_identity_public_key(public_key):
            return BootstrapRecordValidation(False, "user_id does not match identity key")
        issued_at = _parse_time(record["issued_at"])
        expires_at = _parse_time(record["expires_at"])
    except (KeyError, TypeError, ValueError):
        return BootstrapRecordValidation(False, "malformed record")
    lifetime = expires_at - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return BootstrapRecordValidation(False, "invalid record lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return BootstrapRecordValidation(False, "record is not yet valid")
    if now_utc - CLOCK_SKEW > expires_at:
        return BootstrapRecordValidation(False, "record has expired")
    if not isinstance(record.get("signature"), str) or not verify_message(
        public_key_text,
        bootstrap_record_signing_payload(record),
        record["signature"],
    ):
        return BootstrapRecordValidation(False, "invalid identity signature")
    return BootstrapRecordValidation(True)
