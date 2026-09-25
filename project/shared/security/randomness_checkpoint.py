"""Quorum-approved randomness and observer snapshot for challenge scheduling."""

from __future__ import annotations

import copy
import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-randomness-checkpoint/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/RANDOMNESS_CHECKPOINT/v1\x00"
MAX_LIFETIME = timedelta(days=1)
CLOCK_SKEW = timedelta(minutes=5)
MAX_ELIGIBLE_OBSERVERS = 2_048
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "challenge_epoch",
    "authority_epoch",
    "previous_hash",
    "randomness_seed",
    "eligible_observers",
    "observer_count",
    "issued_at",
    "valid_until",
    "committee",
    "threshold",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class RandomnessCheckpointValidation:
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


def _normalize_observers(
    eligible_observers: Sequence[Mapping[str, str]],
) -> list[dict[str, str]]:
    normalized = [
        {
            "node_id": item["node_id"],
            "diversity_group": item["diversity_group"],
        }
        for item in eligible_observers
    ]
    return sorted(normalized, key=lambda item: item["node_id"])


def randomness_checkpoint_signing_payload(checkpoint: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: checkpoint[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def randomness_checkpoint_hash(checkpoint: Mapping[str, Any]) -> str:
    return hashlib.sha256(randomness_checkpoint_signing_payload(checkpoint)).hexdigest()


def build_randomness_checkpoint(
    *,
    challenge_epoch: int,
    authority_epoch: int,
    previous_hash: str,
    randomness_seed: str,
    eligible_observers: Sequence[Mapping[str, str]],
    observer_count: int,
    issued_at: datetime,
    valid_until: datetime,
    committee: Sequence[str],
    threshold: int,
) -> dict[str, Any]:
    if valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("randomness checkpoint lifetime exceeds one day")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "challenge_epoch": challenge_epoch,
        "authority_epoch": authority_epoch,
        "previous_hash": previous_hash,
        "randomness_seed": randomness_seed,
        "eligible_observers": _normalize_observers(eligible_observers),
        "observer_count": observer_count,
        "issued_at": _utc_iso(issued_at),
        "valid_until": _utc_iso(valid_until),
        "committee": sorted(committee),
        "threshold": threshold,
        "signatures": [],
    }


def add_randomness_signature(
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
                validator_signing_key,
                randomness_checkpoint_signing_payload(result),
            ),
        }
    )
    return result


def _structural_error(checkpoint: Mapping[str, Any]) -> str | None:
    if set(checkpoint) != _ALL_FIELDS:
        return "invalid randomness checkpoint fields"
    if checkpoint.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if checkpoint.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    for field in ("challenge_epoch", "authority_epoch"):
        value = checkpoint.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return f"invalid {field}"
    for field in ("previous_hash", "randomness_seed"):
        if re.fullmatch(r"[0-9a-f]{64}", checkpoint.get(field, "")) is None:
            return f"invalid {field}"
    observers = checkpoint.get("eligible_observers")
    if (
        not isinstance(observers, list)
        or not observers
        or len(observers) > MAX_ELIGIBLE_OBSERVERS
    ):
        return "invalid eligible_observers"
    normalized = []
    for item in observers:
        if not isinstance(item, dict) or set(item) != {"node_id", "diversity_group"}:
            return "invalid eligible observer"
        node_id = item.get("node_id")
        diversity_group = item.get("diversity_group")
        if (
            not isinstance(node_id, str)
            or not node_id.startswith(NODE_ID_PREFIX)
            or not isinstance(diversity_group, str)
            or not diversity_group
            or len(diversity_group) > 128
        ):
            return "invalid eligible observer"
        normalized.append({"node_id": node_id, "diversity_group": diversity_group})
    if observers != sorted(normalized, key=lambda item: item["node_id"]):
        return "eligible_observers must be sorted"
    if len({item["node_id"] for item in observers}) != len(observers):
        return "duplicate eligible observer"
    observer_count = checkpoint.get("observer_count")
    if (
        not isinstance(observer_count, int)
        or isinstance(observer_count, bool)
        or not 1 <= observer_count <= min(15, len(observers))
    ):
        return "invalid observer_count"
    committee = checkpoint.get("committee")
    if (
        not isinstance(committee, list)
        or not committee
        or any(not isinstance(item, str) or not item for item in committee)
        or committee != sorted(set(committee))
    ):
        return "invalid committee"
    threshold = checkpoint.get("threshold")
    if (
        not isinstance(threshold, int)
        or isinstance(threshold, bool)
        or not 1 <= threshold <= len(committee)
    ):
        return "invalid threshold"
    if not isinstance(checkpoint.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_randomness_checkpoint(
    checkpoint: Mapping[str, Any],
    *,
    now: datetime,
    authority_state: CapabilityAuthorityState,
    expected_previous_hash: str,
    minimum_challenge_epoch: int,
) -> RandomnessCheckpointValidation:
    if not isinstance(checkpoint, Mapping):
        return RandomnessCheckpointValidation(False, "checkpoint must be an object")
    error = _structural_error(checkpoint)
    if error:
        return RandomnessCheckpointValidation(False, error)
    if checkpoint["authority_epoch"] != authority_state.epoch:
        return RandomnessCheckpointValidation(False, "authority epoch mismatch")
    if checkpoint["committee"] != list(authority_state.committee):
        return RandomnessCheckpointValidation(False, "committee does not match authority")
    if checkpoint["threshold"] != authority_state.threshold:
        return RandomnessCheckpointValidation(False, "threshold does not match authority")
    if checkpoint["previous_hash"] != expected_previous_hash:
        return RandomnessCheckpointValidation(False, "randomness checkpoint chain is broken")
    if checkpoint["challenge_epoch"] != minimum_challenge_epoch + 1:
        return RandomnessCheckpointValidation(False, "challenge epoch must advance exactly once")
    if now.tzinfo is None or now.utcoffset() is None:
        return RandomnessCheckpointValidation(False, "validation time must be timezone-aware")
    try:
        issued_at = _parse_time(checkpoint["issued_at"])
        valid_until = _parse_time(checkpoint["valid_until"])
    except (TypeError, ValueError):
        return RandomnessCheckpointValidation(False, "malformed checkpoint time")
    lifetime = valid_until - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return RandomnessCheckpointValidation(False, "invalid checkpoint lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < issued_at:
        return RandomnessCheckpointValidation(False, "checkpoint is not yet valid")
    if now_utc - CLOCK_SKEW > valid_until:
        return RandomnessCheckpointValidation(False, "checkpoint has expired")

    payload = randomness_checkpoint_signing_payload(checkpoint)
    seen: set[str] = set()
    valid_count = 0
    for entry in checkpoint["signatures"]:
        if not isinstance(entry, dict) or set(entry) != {"validator_id", "signature"}:
            return RandomnessCheckpointValidation(False, "malformed validator signature", valid_count)
        validator_id = entry["validator_id"]
        if validator_id in seen:
            return RandomnessCheckpointValidation(False, "duplicate validator signature", valid_count)
        seen.add(validator_id)
        if validator_id not in authority_state.committee:
            return RandomnessCheckpointValidation(False, "signature outside authority", valid_count)
        credential = authority_state.validators.get(validator_id)
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
    if valid_count < authority_state.threshold:
        return RandomnessCheckpointValidation(
            False,
            "insufficient authority signatures",
            valid_count,
        )
    return RandomnessCheckpointValidation(True, valid_signatures=valid_count)
