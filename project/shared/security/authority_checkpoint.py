"""Quorum-signed OUO AuthorityCheckpoint transition object."""

from __future__ import annotations

import base64
import copy
import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import sign_message, verify_message


PROTOCOL_VERSION = "ouo-authority-checkpoint/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/AUTHORITY_CHECKPOINT/v1\x00"
STATE_HASH_DOMAIN = b"OUO/AUTHORITY_STATE/v1\x00"
MAX_LIFETIME = timedelta(days=30)
CLOCK_SKEW = timedelta(minutes=5)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "authority_epoch",
    "previous_hash",
    "committee",
    "threshold",
    "validators",
    "issued_at",
    "valid_until",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class AuthorityCheckpointValidation:
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


def _credential_object(credential: ValidatorCredential) -> dict[str, Any]:
    return {
        "public_key": credential.public_key,
        "valid_until": _utc_iso(credential.valid_until),
        "revoked": credential.revoked,
    }


def authority_state_hash(state: CapabilityAuthorityState) -> str:
    normalized = {
        "epoch": state.epoch,
        "committee": list(state.committee),
        "threshold": state.threshold,
        "validators": {
            validator_id: _credential_object(state.validators[validator_id])
            for validator_id in sorted(state.validators)
        },
    }
    return hashlib.sha256(
        STATE_HASH_DOMAIN + canonical_json(normalized).encode("utf-8")
    ).hexdigest()


def checkpoint_signing_payload(checkpoint: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: checkpoint[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def authority_checkpoint_hash(checkpoint: Mapping[str, Any]) -> str:
    return hashlib.sha256(checkpoint_signing_payload(checkpoint)).hexdigest()


def build_authority_checkpoint(
    *,
    authority_epoch: int,
    previous_hash: str,
    committee: Sequence[str],
    threshold: int,
    validators: Mapping[str, ValidatorCredential],
    issued_at: datetime,
    valid_until: datetime,
) -> dict[str, Any]:
    if valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("authority checkpoint lifetime exceeds 30 days")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "authority_epoch": authority_epoch,
        "previous_hash": previous_hash,
        "committee": sorted(committee),
        "threshold": threshold,
        "validators": {
            validator_id: _credential_object(validators[validator_id])
            for validator_id in sorted(validators)
        },
        "issued_at": _utc_iso(issued_at),
        "valid_until": _utc_iso(valid_until),
        "signatures": [],
    }


def add_authority_signature(
    checkpoint: Mapping[str, Any],
    *,
    validator_id: str,
    validator_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(checkpoint))
    result.setdefault("signatures", []).append(
        {
            "validator_id": validator_id,
            "signature": sign_message(
                validator_signing_key, checkpoint_signing_payload(result)
            ),
        }
    )
    return result


def _valid_public_key(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return len(base64.urlsafe_b64decode(value.encode())) == 32
    except Exception:
        return False


def _structural_error(checkpoint: Mapping[str, Any]) -> str | None:
    if set(checkpoint) != _ALL_FIELDS:
        return "invalid checkpoint fields"
    if checkpoint.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if checkpoint.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    epoch = checkpoint.get("authority_epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        return "invalid authority_epoch"
    previous_hash = checkpoint.get("previous_hash")
    if not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None:
        return "invalid previous_hash"
    committee = checkpoint.get("committee")
    if (
        not isinstance(committee, list)
        or not committee
        or any(not isinstance(item, str) or not item for item in committee)
        or committee != sorted(set(committee))
    ):
        return "invalid committee"
    threshold = checkpoint.get("threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        return "invalid threshold"
    validators = checkpoint.get("validators")
    if not isinstance(validators, dict) or set(validators) != set(committee):
        return "validators must exactly match committee"
    for credential in validators.values():
        if not isinstance(credential, dict) or set(credential) != {
            "public_key",
            "valid_until",
            "revoked",
        }:
            return "invalid validator credential"
        if not _valid_public_key(credential["public_key"]) or not isinstance(
            credential["revoked"], bool
        ):
            return "invalid validator credential"
        try:
            _parse_time(credential["valid_until"])
        except (TypeError, ValueError):
            return "invalid validator credential"
    if not isinstance(checkpoint.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_authority_checkpoint(
    checkpoint: Mapping[str, Any],
    *,
    now: datetime,
    previous_state: CapabilityAuthorityState,
    expected_previous_hash: str,
) -> AuthorityCheckpointValidation:
    if not isinstance(checkpoint, Mapping):
        return AuthorityCheckpointValidation(False, "checkpoint must be an object")
    error = _structural_error(checkpoint)
    if error:
        return AuthorityCheckpointValidation(False, error)
    if checkpoint["authority_epoch"] != previous_state.epoch + 1:
        return AuthorityCheckpointValidation(False, "authority epoch must advance exactly once")
    if checkpoint["previous_hash"] != expected_previous_hash:
        return AuthorityCheckpointValidation(False, "authority checkpoint chain is broken")
    if now.tzinfo is None or now.utcoffset() is None:
        return AuthorityCheckpointValidation(False, "validation time must be timezone-aware")
    try:
        issued_at = _parse_time(checkpoint["issued_at"])
        valid_until = _parse_time(checkpoint["valid_until"])
    except (TypeError, ValueError):
        return AuthorityCheckpointValidation(False, "malformed checkpoint time")
    lifetime = valid_until - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AuthorityCheckpointValidation(False, "invalid checkpoint lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return AuthorityCheckpointValidation(False, "checkpoint is not yet valid")
    if now_utc - CLOCK_SKEW > valid_until:
        return AuthorityCheckpointValidation(False, "checkpoint has expired")
    for credential in checkpoint["validators"].values():
        if _parse_time(credential["valid_until"]) < valid_until:
            return AuthorityCheckpointValidation(
                False, "new validator expires before checkpoint"
            )

    payload = checkpoint_signing_payload(checkpoint)
    seen: set[str] = set()
    valid_count = 0
    for entry in checkpoint["signatures"]:
        if not isinstance(entry, dict) or set(entry) != {"validator_id", "signature"}:
            return AuthorityCheckpointValidation(False, "malformed validator signature", valid_count)
        validator_id = entry["validator_id"]
        if validator_id in seen:
            return AuthorityCheckpointValidation(False, "duplicate validator signature", valid_count)
        seen.add(validator_id)
        if validator_id not in previous_state.committee:
            return AuthorityCheckpointValidation(False, "signature outside previous committee", valid_count)
        credential = previous_state.validators.get(validator_id)
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
    if valid_count < previous_state.threshold:
        return AuthorityCheckpointValidation(
            False, "insufficient previous-authority signatures", valid_count
        )
    return AuthorityCheckpointValidation(True, valid_signatures=valid_count)


def authority_state_from_checkpoint(
    checkpoint: Mapping[str, Any],
) -> CapabilityAuthorityState:
    error = _structural_error(checkpoint)
    if error:
        raise ValueError(error)
    return CapabilityAuthorityState(
        epoch=checkpoint["authority_epoch"],
        committee=tuple(checkpoint["committee"]),
        threshold=checkpoint["threshold"],
        validators={
            validator_id: ValidatorCredential(
                public_key=credential["public_key"],
                valid_until=_parse_time(credential["valid_until"]),
                revoked=credential["revoked"],
            )
            for validator_id, credential in checkpoint["validators"].items()
        },
    )
