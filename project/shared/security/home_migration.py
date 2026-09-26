"""Endpoint-authorized Home Node migration ticket primitives.

The ticket contains no private key, password hash, message plaintext, or
conversation history.  It binds one short-lived migration operation to an
identity, an exact source/destination Home pair, a route epoch, and the hash
of the public device manifest that the destination is allowed to import.
"""

import base64
import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional
from urllib.parse import urlsplit

from nacl.signing import SigningKey

from shared.security.bootstrap_record import user_id_from_identity_public_key
from shared.security.canonical import canonical_json
from shared.security.keys import public_key_b64, sign_message, verify_message
from shared.security.nonce_store import NonceStore


PROTOCOL_VERSION = "ouo-home-migration/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/HOME_MIGRATION/v1\x00"
MAX_LIFETIME = timedelta(minutes=15)
CLOCK_SKEW = timedelta(minutes=2)
_UNSIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "migration_id",
    "user_id",
    "identity_public_key",
    "identity_version",
    "route_epoch",
    "from_home",
    "to_home",
    "device_manifest_hash",
    "issued_at",
    "expires_at",
    "nonce",
}
_ALL_FIELDS = _UNSIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class HomeMigrationValidation:
    valid: bool
    reason: Optional[str] = None


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _valid_home_url(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > 2048:
        return False
    parsed = urlsplit(value)
    return bool(
        parsed.scheme == "https"
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def _valid_sha256(value: Any) -> bool:
    if not isinstance(value, str) or len(value) != 64:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return value == value.lower()


def device_manifest_hash(manifest: Mapping[str, Any]) -> str:
    """Hash the exact public import manifest using canonical JSON."""
    return hashlib.sha256(canonical_json(dict(manifest)).encode("utf-8")).hexdigest()


def home_migration_signing_payload(ticket: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: ticket[field] for field in _UNSIGNED_FIELDS}
    ).encode("utf-8")


def issue_home_migration_ticket(
    *,
    identity_signing_key: SigningKey,
    identity_version: int,
    route_epoch: int,
    from_home: str,
    to_home: str,
    manifest_hash: str,
    issued_at: datetime,
    expires_at: datetime,
    migration_id: Optional[str] = None,
    nonce: Optional[bytes] = None,
) -> dict[str, Any]:
    identity_public_key = bytes(identity_signing_key.verify_key)
    nonce_bytes = nonce if nonce is not None else secrets.token_bytes(32)
    if len(nonce_bytes) != 32:
        raise ValueError("nonce must contain 32 bytes")
    ticket = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "migration_id": migration_id or str(uuid.uuid4()),
        "user_id": user_id_from_identity_public_key(identity_public_key),
        "identity_public_key": public_key_b64(identity_signing_key),
        "identity_version": identity_version,
        "route_epoch": route_epoch,
        "from_home": from_home,
        "to_home": to_home,
        "device_manifest_hash": manifest_hash,
        "issued_at": _utc_iso(issued_at),
        "expires_at": _utc_iso(expires_at),
        "nonce": base64.b64encode(nonce_bytes).decode("ascii"),
    }
    ticket["signature"] = sign_message(
        identity_signing_key, home_migration_signing_payload(ticket)
    )
    return ticket


def validate_home_migration_ticket(
    ticket: Mapping[str, Any],
    *,
    now: datetime,
    expected_user_id: Optional[str] = None,
    expected_from_home: Optional[str] = None,
    expected_to_home: Optional[str] = None,
    expected_manifest_hash: Optional[str] = None,
    minimum_identity_version: int = 1,
    minimum_route_epoch: int = 0,
) -> HomeMigrationValidation:
    if not isinstance(ticket, Mapping) or set(ticket) != _ALL_FIELDS:
        return HomeMigrationValidation(False, "invalid ticket fields")
    if ticket.get("protocol_version") != PROTOCOL_VERSION:
        return HomeMigrationValidation(False, "unsupported protocol_version")
    if ticket.get("object_version") != OBJECT_VERSION:
        return HomeMigrationValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(ticket["migration_id"])) != ticket["migration_id"]:
            return HomeMigrationValidation(False, "invalid migration_id")
    except (AttributeError, TypeError, ValueError):
        return HomeMigrationValidation(False, "invalid migration_id")
    if not _valid_home_url(ticket.get("from_home")) or not _valid_home_url(
        ticket.get("to_home")
    ):
        return HomeMigrationValidation(False, "invalid Home URL")
    if ticket["from_home"] == ticket["to_home"]:
        return HomeMigrationValidation(False, "source and destination Home are equal")
    if not _valid_sha256(ticket.get("device_manifest_hash")):
        return HomeMigrationValidation(False, "invalid device manifest hash")
    if expected_from_home is not None and ticket["from_home"] != expected_from_home:
        return HomeMigrationValidation(False, "unexpected source Home")
    if expected_to_home is not None and ticket["to_home"] != expected_to_home:
        return HomeMigrationValidation(False, "unexpected destination Home")
    if (
        expected_manifest_hash is not None
        and ticket["device_manifest_hash"] != expected_manifest_hash
    ):
        return HomeMigrationValidation(False, "device manifest hash mismatch")
    identity_version = ticket.get("identity_version")
    route_epoch = ticket.get("route_epoch")
    if (
        not isinstance(identity_version, int)
        or isinstance(identity_version, bool)
        or identity_version < minimum_identity_version
    ):
        return HomeMigrationValidation(False, "invalid or stale identity_version")
    if (
        not isinstance(route_epoch, int)
        or isinstance(route_epoch, bool)
        or route_epoch < minimum_route_epoch
    ):
        return HomeMigrationValidation(False, "invalid or stale route_epoch")
    if now.tzinfo is None or now.utcoffset() is None:
        return HomeMigrationValidation(False, "validation time must be timezone-aware")
    try:
        identity_public_key_text = ticket["identity_public_key"]
        identity_public_key = base64.b64decode(
            identity_public_key_text.encode("ascii"), altchars=b"-_", validate=True
        )
        if len(identity_public_key) != 32:
            raise ValueError("wrong key length")
        derived_user_id = user_id_from_identity_public_key(identity_public_key)
        issued_at = _parse_time(ticket["issued_at"])
        expires_at = _parse_time(ticket["expires_at"])
        nonce = base64.b64decode(ticket["nonce"], validate=True)
    except (KeyError, TypeError, ValueError):
        return HomeMigrationValidation(False, "malformed ticket")
    if len(nonce) != 32:
        return HomeMigrationValidation(False, "invalid nonce")
    if ticket.get("user_id") != derived_user_id:
        return HomeMigrationValidation(False, "user_id does not match identity key")
    if expected_user_id is not None and derived_user_id != expected_user_id:
        return HomeMigrationValidation(False, "unexpected user_id")
    lifetime = expires_at - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return HomeMigrationValidation(False, "invalid ticket lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return HomeMigrationValidation(False, "ticket is not yet valid")
    if now_utc - CLOCK_SKEW > expires_at:
        return HomeMigrationValidation(False, "ticket has expired")
    signature = ticket.get("signature")
    if not isinstance(signature, str) or not verify_message(
        identity_public_key_text,
        home_migration_signing_payload(ticket),
        signature,
    ):
        return HomeMigrationValidation(False, "invalid identity signature")
    return HomeMigrationValidation(True)


def validate_and_consume_home_migration_ticket(
    ticket: Mapping[str, Any],
    *,
    nonce_store: NonceStore,
    now: datetime,
    expected_user_id: Optional[str] = None,
    expected_from_home: Optional[str] = None,
    expected_to_home: Optional[str] = None,
    expected_manifest_hash: Optional[str] = None,
    minimum_identity_version: int = 1,
    minimum_route_epoch: int = 0,
) -> HomeMigrationValidation:
    """Validate and atomically mark a migration ticket as consumed.

    Consumers must call this only at the state-changing import boundary.  A
    read-only preview should call :func:`validate_home_migration_ticket` so it
    cannot accidentally burn the single-use authorization.
    """
    result = validate_home_migration_ticket(
        ticket,
        now=now,
        expected_user_id=expected_user_id,
        expected_from_home=expected_from_home,
        expected_to_home=expected_to_home,
        expected_manifest_hash=expected_manifest_hash,
        minimum_identity_version=minimum_identity_version,
        minimum_route_epoch=minimum_route_epoch,
    )
    if not result.valid:
        return result
    replay_key = f"home-migration:{ticket['migration_id']}:{ticket['nonce']}"
    if not nonce_store.consume(
        replay_key,
        str(ticket["user_id"]),
        int(MAX_LIFETIME.total_seconds() + CLOCK_SKEW.total_seconds()),
    ):
        return HomeMigrationValidation(False, "migration ticket already consumed")
    return result
