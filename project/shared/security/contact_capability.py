"""Endpoint-signed, quota-limited capability for an initial contact request."""

from __future__ import annotations

import base64
import hmac
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.mailbox_capability import mailbox_token_bytes


PROTOCOL_VERSION = "ouo-contact-capability/1"
MAX_LIFETIME = timedelta(days=30)
MAX_REQUESTS = 8
DOMAIN = b"OUO/CONTACT_CAPABILITY/v1\x00"
UNSIGNED_FIELDS = {
    "protocol_version", "capability_id", "issuer_public_key", "mailbox_token",
    "permissions", "max_requests", "issued_at", "expires_at",
}
ALL_FIELDS = UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class ContactCapabilityValidation:
    valid: bool
    reason: str | None = None


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


def _payload(value: Mapping[str, Any]) -> bytes:
    return DOMAIN + canonical_json({field: value[field] for field in UNSIGNED_FIELDS}).encode()


def issue_contact_capability(
    *, issuer_signing_key: SigningKey, mailbox_token: str, issued_at: datetime,
    expires_at: datetime, max_requests: int = 1,
) -> dict[str, Any]:
    mailbox_token_bytes(mailbox_token)
    if (
        issued_at.tzinfo is None
        or issued_at.utcoffset() is None
        or expires_at.tzinfo is None
        or expires_at.utcoffset() is None
    ):
        raise ValueError("contact capability timestamps must be timezone-aware")
    if not 1 <= max_requests <= MAX_REQUESTS:
        raise ValueError("invalid contact capability quota")
    lifetime = expires_at.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc)
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        raise ValueError("invalid contact capability lifetime")
    value = {
        "protocol_version": PROTOCOL_VERSION,
        "capability_id": str(uuid.uuid4()),
        "issuer_public_key": base64.urlsafe_b64encode(bytes(issuer_signing_key.verify_key)).decode(),
        "mailbox_token": mailbox_token,
        "permissions": ["initial_contact_text"],
        "max_requests": max_requests,
        "issued_at": _iso(issued_at),
        "expires_at": _iso(expires_at),
    }
    value["signature"] = sign_message(issuer_signing_key, _payload(value))
    return value


def validate_contact_capability(
    value: Mapping[str, Any], *, now: datetime, expected_issuer_public_key: str,
) -> ContactCapabilityValidation:
    if now.tzinfo is None or now.utcoffset() is None:
        return ContactCapabilityValidation(False, "validation time must be timezone-aware")
    if not isinstance(value, Mapping) or set(value) != ALL_FIELDS:
        return ContactCapabilityValidation(False, "invalid contact capability fields")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        return ContactCapabilityValidation(False, "unsupported protocol version")
    if not expected_issuer_public_key:
        return ContactCapabilityValidation(False, "expected issuer identity is required")
    try:
        if str(uuid.UUID(value["capability_id"])) != value["capability_id"]:
            raise ValueError
        mailbox_token_bytes(value["mailbox_token"])
        public_key = base64.b64decode(value["issuer_public_key"], altchars=b"-_", validate=True)
        issued_at = _time(value["issued_at"])
        expires_at = _time(value["expires_at"])
    except (KeyError, TypeError, ValueError):
        return ContactCapabilityValidation(False, "malformed contact capability")
    if len(public_key) != 32:
        return ContactCapabilityValidation(False, "invalid issuer public key")
    if not hmac.compare_digest(
        value["issuer_public_key"], expected_issuer_public_key
    ):
        return ContactCapabilityValidation(False, "contact capability issuer mismatch")
    if value.get("permissions") != ["initial_contact_text"]:
        return ContactCapabilityValidation(False, "invalid contact permissions")
    quota = value.get("max_requests")
    if not isinstance(quota, int) or isinstance(quota, bool) or not 1 <= quota <= MAX_REQUESTS:
        return ContactCapabilityValidation(False, "invalid contact quota")
    lifetime = expires_at - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return ContactCapabilityValidation(False, "invalid contact capability lifetime")
    current = now.astimezone(timezone.utc)
    if current < issued_at or current > expires_at:
        return ContactCapabilityValidation(False, "contact capability is not active")
    if not verify_message(value["issuer_public_key"], _payload(value), value["signature"]):
        return ContactCapabilityValidation(False, "invalid contact capability signature")
    return ContactCapabilityValidation(True)
