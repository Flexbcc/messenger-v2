"""Threshold emergency recovery authorization for a replacement authority set."""

from __future__ import annotations

import copy
import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.authority_checkpoint import (
    authority_checkpoint_hash,
    authority_state_from_checkpoint,
)
from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import sign_message, verify_message


PROTOCOL_VERSION = "ouo-authority-recovery/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/AUTHORITY_RECOVERY/v1\x00"
HASH_DOMAIN = b"OUO/AUTHORITY_RECOVERY_HASH/v1\x00"
MAX_LIFETIME = timedelta(hours=24)
CLOCK_SKEW = timedelta(minutes=5)
REASON_CODES = frozenset(
    {"authority_quorum_compromise", "catastrophic_recovery", "protocol_recovery"}
)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "recovery_id",
    "compromised_authority_epoch",
    "replacement_checkpoint",
    "reason_code",
    "issued_at",
    "expires_at",
    "recovery_committee",
    "recovery_threshold",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class AuthorityRecoveryValidation:
    valid: bool
    reason: str | None = None
    valid_signatures: int = 0


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


def authority_recovery_signing_payload(recovery: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: recovery[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def authority_recovery_hash(recovery: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        HASH_DOMAIN + authority_recovery_signing_payload(recovery)
    ).hexdigest()


def build_authority_recovery(
    *,
    compromised_authority_epoch: int,
    replacement_checkpoint: Mapping[str, Any],
    reason_code: str,
    issued_at: datetime,
    expires_at: datetime,
    recovery_committee: tuple[str, ...] | list[str],
    recovery_threshold: int,
    recovery_id: str | None = None,
) -> dict[str, Any]:
    if expires_at.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("authority recovery lifetime exceeds 24 hours")
    recovery = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "recovery_id": recovery_id or str(uuid.uuid4()),
        "compromised_authority_epoch": compromised_authority_epoch,
        "replacement_checkpoint": copy.deepcopy(dict(replacement_checkpoint)),
        "reason_code": reason_code,
        "issued_at": _utc_iso(issued_at),
        "expires_at": _utc_iso(expires_at),
        "recovery_committee": sorted(recovery_committee),
        "recovery_threshold": recovery_threshold,
        "signatures": [],
    }
    return recovery


def add_recovery_signature(
    recovery: Mapping[str, Any],
    *,
    recovery_key_id: str,
    recovery_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(recovery))
    result.setdefault("signatures", []).append(
        {
            "recovery_key_id": recovery_key_id,
            "signature": sign_message(
                recovery_signing_key,
                authority_recovery_signing_payload(result),
            ),
        }
    )
    return result


def _structure_error(recovery: Mapping[str, Any]) -> str | None:
    if set(recovery) != _ALL_FIELDS:
        return "invalid recovery fields"
    if recovery.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if recovery.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    try:
        if str(uuid.UUID(recovery["recovery_id"])) != recovery["recovery_id"]:
            return "invalid recovery_id"
    except (AttributeError, TypeError, ValueError):
        return "invalid recovery_id"
    compromised_epoch = recovery.get("compromised_authority_epoch")
    if (
        not isinstance(compromised_epoch, int)
        or isinstance(compromised_epoch, bool)
        or compromised_epoch < 0
    ):
        return "invalid compromised_authority_epoch"
    if recovery.get("reason_code") not in REASON_CODES:
        return "invalid recovery reason_code"
    committee = recovery.get("recovery_committee")
    if (
        not isinstance(committee, list)
        or not committee
        or any(not isinstance(item, str) or not item for item in committee)
        or committee != sorted(set(committee))
    ):
        return "invalid recovery committee"
    threshold = recovery.get("recovery_threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        return "invalid recovery threshold"
    if not isinstance(recovery.get("signatures"), list):
        return "invalid recovery signatures"
    replacement = recovery.get("replacement_checkpoint")
    if not isinstance(replacement, Mapping):
        return "invalid replacement checkpoint"
    try:
        authority_state_from_checkpoint(replacement)
    except ValueError as exc:
        return f"invalid replacement checkpoint: {exc}"
    if replacement.get("signatures") != []:
        return "replacement checkpoint must not contain normal-authority signatures"
    previous_hash = replacement.get("previous_hash")
    if not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None:
        return "invalid replacement previous_hash"
    return None


def validate_authority_recovery(
    recovery: Mapping[str, Any],
    *,
    now: datetime,
    recovery_state: CapabilityAuthorityState,
    minimum_authority_epoch: int,
) -> AuthorityRecoveryValidation:
    if not isinstance(recovery, Mapping):
        return AuthorityRecoveryValidation(False, "recovery must be an object")
    error = _structure_error(recovery)
    if error:
        return AuthorityRecoveryValidation(False, error)
    if recovery["recovery_committee"] != list(recovery_state.committee):
        return AuthorityRecoveryValidation(False, "recovery committee does not match offline policy")
    if recovery["recovery_threshold"] != recovery_state.threshold:
        return AuthorityRecoveryValidation(False, "recovery threshold does not match offline policy")
    replacement = recovery["replacement_checkpoint"]
    replacement_epoch = replacement["authority_epoch"]
    if recovery["compromised_authority_epoch"] < minimum_authority_epoch:
        return AuthorityRecoveryValidation(False, "recovery does not cover highest authority epoch")
    if replacement_epoch <= recovery["compromised_authority_epoch"]:
        return AuthorityRecoveryValidation(False, "replacement authority epoch must advance")
    if now.tzinfo is None or now.utcoffset() is None:
        return AuthorityRecoveryValidation(False, "validation time must be timezone-aware")
    try:
        issued_at = _parse_time(recovery["issued_at"])
        expires_at = _parse_time(recovery["expires_at"])
        replacement_issued = _parse_time(replacement["issued_at"])
        replacement_valid_until = _parse_time(replacement["valid_until"])
    except (TypeError, ValueError):
        return AuthorityRecoveryValidation(False, "malformed recovery time")
    lifetime = expires_at - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AuthorityRecoveryValidation(False, "invalid recovery lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return AuthorityRecoveryValidation(False, "recovery is not yet valid")
    if now_utc - CLOCK_SKEW > expires_at:
        return AuthorityRecoveryValidation(False, "recovery has expired")
    if replacement_issued + CLOCK_SKEW < issued_at:
        return AuthorityRecoveryValidation(False, "replacement predates recovery ceremony")
    if replacement_valid_until <= replacement_issued:
        return AuthorityRecoveryValidation(False, "invalid replacement lifetime")
    for credential in replacement["validators"].values():
        try:
            if _parse_time(credential["valid_until"]) < replacement_valid_until:
                return AuthorityRecoveryValidation(
                    False, "replacement validator expires before checkpoint"
                )
        except (KeyError, TypeError, ValueError):
            return AuthorityRecoveryValidation(False, "invalid replacement validator time")

    payload = authority_recovery_signing_payload(recovery)
    seen: set[str] = set()
    valid_count = 0
    for entry in recovery["signatures"]:
        if not isinstance(entry, dict) or set(entry) != {"recovery_key_id", "signature"}:
            return AuthorityRecoveryValidation(False, "malformed recovery signature", valid_count)
        key_id = entry["recovery_key_id"]
        if key_id in seen:
            return AuthorityRecoveryValidation(False, "duplicate recovery signature", valid_count)
        seen.add(key_id)
        if key_id not in recovery_state.committee:
            return AuthorityRecoveryValidation(False, "signature outside recovery committee", valid_count)
        credential = recovery_state.validators.get(key_id)
        if (
            credential is None
            or credential.revoked
            or credential.valid_until.tzinfo is None
            or credential.valid_until.utcoffset() is None
            or credential.valid_until.astimezone(timezone.utc) < now_utc
        ):
            continue
        if verify_message(credential.public_key, payload, entry.get("signature", "")):
            valid_count += 1
    if valid_count < recovery_state.threshold:
        return AuthorityRecoveryValidation(
            False, "insufficient offline recovery signatures", valid_count
        )
    return AuthorityRecoveryValidation(True, valid_signatures=valid_count)


def replacement_checkpoint_hash(recovery: Mapping[str, Any]) -> str:
    return authority_checkpoint_hash(recovery["replacement_checkpoint"])
