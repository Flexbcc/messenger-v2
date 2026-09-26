"""Dual-signed binding between a legacy account id and its Identity Root."""

import base64
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import public_key_b64, sign_message, verify_message


PROTOCOL_VERSION = "ouo-user-identity-binding/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/USER_IDENTITY_BINDING/v1\x00"
MAX_AGE = timedelta(minutes=10)
CLOCK_SKEW = timedelta(minutes=2)
_PAYLOAD_FIELDS = {
    "protocol_version",
    "object_version",
    "binding_id",
    "user_id",
    "identity_public_key",
    "identity_version",
    "authorizing_device_id",
    "authorizing_device_public_key",
    "issued_at",
}
_ALL_FIELDS = _PAYLOAD_FIELDS | {"identity_signature", "device_signature"}


@dataclass(frozen=True)
class UserIdentityBindingValidation:
    valid: bool
    reason: Optional[str] = None


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def user_identity_binding_payload(binding: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: binding[field] for field in _PAYLOAD_FIELDS}
    ).encode("utf-8")


def issue_user_identity_binding(
    *,
    user_id: str,
    identity_signing_key: SigningKey,
    identity_version: int,
    authorizing_device_id: str,
    device_signing_key: SigningKey,
    issued_at: datetime,
    binding_id: Optional[str] = None,
) -> dict[str, Any]:
    binding = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "binding_id": binding_id or str(uuid.uuid4()),
        "user_id": user_id,
        "identity_public_key": public_key_b64(identity_signing_key),
        "identity_version": identity_version,
        "authorizing_device_id": authorizing_device_id,
        "authorizing_device_public_key": public_key_b64(device_signing_key),
        "issued_at": _utc_iso(issued_at),
    }
    payload = user_identity_binding_payload(binding)
    binding["identity_signature"] = sign_message(identity_signing_key, payload)
    binding["device_signature"] = sign_message(device_signing_key, payload)
    return binding


def _valid_public_key(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    return _public_key_bytes(value) is not None


def _public_key_bytes(value: str) -> Optional[bytes]:
    try:
        raw = base64.b64decode(value, altchars=b"-_", validate=True)
    except (TypeError, ValueError):
        return None
    return raw if len(raw) == 32 else None


def validate_user_identity_binding(
    binding: Mapping[str, Any],
    *,
    now: datetime,
    expected_user_id: str,
    expected_device_id: str,
    expected_device_public_key: str,
    current_identity_public_key: Optional[str] = None,
    minimum_identity_version: int = 1,
) -> UserIdentityBindingValidation:
    if not isinstance(binding, Mapping) or set(binding) != _ALL_FIELDS:
        return UserIdentityBindingValidation(False, "invalid binding fields")
    if binding.get("protocol_version") != PROTOCOL_VERSION:
        return UserIdentityBindingValidation(False, "unsupported protocol_version")
    if binding.get("object_version") != OBJECT_VERSION:
        return UserIdentityBindingValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(binding["binding_id"])) != binding["binding_id"]:
            return UserIdentityBindingValidation(False, "invalid binding_id")
    except (AttributeError, TypeError, ValueError):
        return UserIdentityBindingValidation(False, "invalid binding_id")
    if binding.get("user_id") != expected_user_id:
        return UserIdentityBindingValidation(False, "unexpected user_id")
    if binding.get("authorizing_device_id") != expected_device_id:
        return UserIdentityBindingValidation(False, "unexpected authorizing device")
    if _public_key_bytes(binding.get("authorizing_device_public_key")) != _public_key_bytes(
        expected_device_public_key
    ):
        return UserIdentityBindingValidation(False, "device key mismatch")
    identity_key = binding.get("identity_public_key")
    if not _valid_public_key(identity_key) or not _valid_public_key(
        binding.get("authorizing_device_public_key")
    ):
        return UserIdentityBindingValidation(False, "invalid public key")
    version = binding.get("identity_version")
    if (
        not isinstance(version, int)
        or isinstance(version, bool)
        or version < minimum_identity_version
    ):
        return UserIdentityBindingValidation(False, "invalid or stale identity_version")
    if (
        current_identity_public_key is not None
        and _public_key_bytes(identity_key) != _public_key_bytes(current_identity_public_key)
    ):
        return UserIdentityBindingValidation(False, "Identity Root replacement requires transition")
    if now.tzinfo is None or now.utcoffset() is None:
        return UserIdentityBindingValidation(False, "validation time must be timezone-aware")
    try:
        value = binding["issued_at"]
        if not isinstance(value, str):
            raise ValueError("invalid issued_at")
        issued_at = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
        if issued_at.tzinfo is None or issued_at.utcoffset() is None:
            raise ValueError("invalid issued_at")
        issued_at = issued_at.astimezone(timezone.utc)
    except (KeyError, TypeError, ValueError):
        return UserIdentityBindingValidation(False, "malformed issued_at")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return UserIdentityBindingValidation(False, "binding is from the future")
    if now_utc - issued_at > MAX_AGE + CLOCK_SKEW:
        return UserIdentityBindingValidation(False, "binding has expired")
    payload = user_identity_binding_payload(binding)
    if not verify_message(identity_key, payload, binding.get("identity_signature", "")):
        return UserIdentityBindingValidation(False, "invalid Identity Root signature")
    if not verify_message(
        expected_device_public_key, payload, binding.get("device_signature", "")
    ):
        return UserIdentityBindingValidation(False, "invalid device signature")
    return UserIdentityBindingValidation(True)
