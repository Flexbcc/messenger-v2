"""Signed source announcement for AuthorityCheckpoint gossip."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-authority-gossip/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/AUTHORITY_GOSSIP/v1\x00"
MAX_LIFETIME = timedelta(minutes=10)
CLOCK_SKEW = timedelta(minutes=2)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "announcement_id",
    "source_node_id",
    "authority_epoch",
    "checkpoint_hash",
    "announced_at",
    "expires_at",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class AuthorityAnnouncementValidation:
    valid: bool
    reason: str | None = None


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


def authority_announcement_signing_payload(announcement: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: announcement[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def issue_authority_announcement(
    *,
    source_node_id: str,
    authority_epoch: int,
    checkpoint_hash: str,
    announced_at: datetime,
    expires_at: datetime,
    source_signing_key: SigningKey,
    announcement_id: str | None = None,
) -> dict[str, Any]:
    if expires_at.astimezone(timezone.utc) - announced_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("authority announcement lifetime exceeds ten minutes")
    announcement = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "announcement_id": announcement_id or str(uuid.uuid4()),
        "source_node_id": source_node_id,
        "authority_epoch": authority_epoch,
        "checkpoint_hash": checkpoint_hash,
        "announced_at": _utc_iso(announced_at),
        "expires_at": _utc_iso(expires_at),
    }
    announcement["signature"] = sign_message(
        source_signing_key,
        authority_announcement_signing_payload(announcement),
    )
    return announcement


def validate_authority_announcement(
    announcement: Mapping[str, Any],
    *,
    now: datetime,
    expected_checkpoint_hash: str,
    expected_authority_epoch: int,
    source_credential: ValidatorCredential,
) -> AuthorityAnnouncementValidation:
    if not isinstance(announcement, Mapping) or set(announcement) != _ALL_FIELDS:
        return AuthorityAnnouncementValidation(False, "invalid announcement fields")
    if announcement.get("protocol_version") != PROTOCOL_VERSION:
        return AuthorityAnnouncementValidation(False, "unsupported protocol_version")
    if announcement.get("object_version") != OBJECT_VERSION:
        return AuthorityAnnouncementValidation(False, "unsupported object_version")
    try:
        if str(uuid.UUID(announcement["announcement_id"])) != announcement["announcement_id"]:
            return AuthorityAnnouncementValidation(False, "invalid announcement_id")
    except (AttributeError, TypeError, ValueError):
        return AuthorityAnnouncementValidation(False, "invalid announcement_id")
    source_node_id = announcement.get("source_node_id")
    if not isinstance(source_node_id, str) or not source_node_id.startswith(NODE_ID_PREFIX):
        return AuthorityAnnouncementValidation(False, "invalid source_node_id")
    epoch = announcement.get("authority_epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch != expected_authority_epoch:
        return AuthorityAnnouncementValidation(False, "announcement authority_epoch mismatch")
    digest = announcement.get("checkpoint_hash")
    if (
        not isinstance(digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        or digest != expected_checkpoint_hash
    ):
        return AuthorityAnnouncementValidation(False, "announcement checkpoint_hash mismatch")
    if not isinstance(announcement.get("signature"), str):
        return AuthorityAnnouncementValidation(False, "invalid announcement signature encoding")
    if now.tzinfo is None or now.utcoffset() is None:
        return AuthorityAnnouncementValidation(False, "validation time must be timezone-aware")
    try:
        announced_at = _parse_time(announcement["announced_at"])
        expires_at = _parse_time(announcement["expires_at"])
    except (TypeError, ValueError):
        return AuthorityAnnouncementValidation(False, "malformed announcement time")
    lifetime = expires_at - announced_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AuthorityAnnouncementValidation(False, "invalid announcement lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < announced_at:
        return AuthorityAnnouncementValidation(False, "announcement is from the future")
    if now_utc - CLOCK_SKEW > expires_at:
        return AuthorityAnnouncementValidation(False, "announcement has expired")
    if source_credential.revoked:
        return AuthorityAnnouncementValidation(False, "source credential is revoked")
    if (
        source_credential.valid_until.tzinfo is None
        or source_credential.valid_until.utcoffset() is None
        or source_credential.valid_until.astimezone(timezone.utc) < now_utc
    ):
        return AuthorityAnnouncementValidation(False, "source credential has expired")
    if not verify_message(
        source_credential.public_key,
        authority_announcement_signing_payload(announcement),
        announcement["signature"],
    ):
        return AuthorityAnnouncementValidation(False, "invalid source announcement signature")
    return AuthorityAnnouncementValidation(True)
