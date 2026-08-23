"""Quorum-signed synthetic challenge assignment object."""

from __future__ import annotations

import copy
import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX
from shared.security.trust_evidence import CHALLENGE_TYPES


PROTOCOL_VERSION = "ouo-challenge-assignment/2"
OBJECT_VERSION = 2
SIGNING_DOMAIN = b"OUO/CHALLENGE_ASSIGNMENT/v2\x00"
ACK_PROTOCOL_VERSION = "ouo-challenge-assignment-ack/1"
ACK_OBJECT_VERSION = 1
ACK_SIGNING_DOMAIN = b"OUO/CHALLENGE_ASSIGNMENT_ACK/v1\x00"
MAX_LIFETIME = timedelta(hours=1)
CLOCK_SKEW = timedelta(minutes=5)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "assignment_id",
    "subject_node_id",
    "observer_node_ids",
    "challenge_type",
    "epoch",
    "authority_epoch",
    "randomness_commitment",
    "not_before",
    "expires_at",
    "committee",
    "threshold",
    "previous_hash",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}
_ACK_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "assignment_id",
    "observer_node_id",
    "decision",
    "acknowledged_at",
}
_ACK_ALL_FIELDS = _ACK_SIGNED_FIELDS | {"signature"}
ACK_DECISIONS = frozenset({"accepted", "declined"})


@dataclass(frozen=True)
class AssignmentValidation:
    valid: bool
    reason: str | None = None
    valid_signatures: int = 0


@dataclass(frozen=True)
class AssignmentAckValidation:
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


def assignment_signing_payload(assignment: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: assignment[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def challenge_assignment_hash(assignment: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(assignment)).encode("utf-8")).hexdigest()


def challenge_assignment_ack_hash(ack: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(ack)).encode("utf-8")).hexdigest()


def assignment_ack_signing_payload(ack: Mapping[str, Any]) -> bytes:
    return ACK_SIGNING_DOMAIN + canonical_json(
        {field: ack[field] for field in _ACK_SIGNED_FIELDS}
    ).encode("utf-8")


def build_challenge_assignment(
    *,
    subject_node_id: str,
    observer_node_ids: Sequence[str],
    challenge_type: str,
    epoch: int,
    authority_epoch: int | None = None,
    randomness_commitment: str,
    not_before: datetime,
    expires_at: datetime,
    committee: Sequence[str],
    threshold: int,
    previous_hash: str | None = None,
    assignment_id: str | None = None,
) -> dict[str, Any]:
    not_before_text = _utc_iso(not_before)
    expires_at_text = _utc_iso(expires_at)
    if expires_at.astimezone(timezone.utc) - not_before.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("challenge assignment lifetime exceeds one hour")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "assignment_id": assignment_id or str(uuid.uuid4()),
        "subject_node_id": subject_node_id,
        "observer_node_ids": sorted(observer_node_ids),
        "challenge_type": challenge_type,
        "epoch": epoch,
        "authority_epoch": epoch if authority_epoch is None else authority_epoch,
        "randomness_commitment": randomness_commitment,
        "not_before": not_before_text,
        "expires_at": expires_at_text,
        "committee": sorted(committee),
        "threshold": threshold,
        "previous_hash": previous_hash,
        "signatures": [],
    }


def add_assignment_signature(
    assignment: Mapping[str, Any],
    *,
    validator_id: str,
    validator_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(assignment))
    result.setdefault("signatures", []).append(
        {
            "validator_id": validator_id,
            "signature": sign_message(
                validator_signing_key, assignment_signing_payload(result)
            ),
        }
    )
    return result


def issue_assignment_ack(
    *,
    assignment_id: str,
    observer_node_id: str,
    decision: str,
    acknowledged_at: datetime,
    observer_signing_key: SigningKey,
) -> dict[str, Any]:
    ack = {
        "protocol_version": ACK_PROTOCOL_VERSION,
        "object_version": ACK_OBJECT_VERSION,
        "assignment_id": assignment_id,
        "observer_node_id": observer_node_id,
        "decision": decision,
        "acknowledged_at": _utc_iso(acknowledged_at),
    }
    ack["signature"] = sign_message(
        observer_signing_key, assignment_ack_signing_payload(ack)
    )
    return ack


def validate_assignment_ack(
    ack: Mapping[str, Any],
    *,
    now: datetime,
    expected_assignment_id: str,
    expected_observer_node_id: str,
    observer_credential: ValidatorCredential,
    assignment_not_before: datetime,
    assignment_expires_at: datetime,
) -> AssignmentAckValidation:
    if not isinstance(ack, Mapping) or set(ack) != _ACK_ALL_FIELDS:
        return AssignmentAckValidation(False, "invalid assignment ack fields")
    if ack.get("protocol_version") != ACK_PROTOCOL_VERSION:
        return AssignmentAckValidation(False, "unsupported ack protocol_version")
    if ack.get("object_version") != ACK_OBJECT_VERSION:
        return AssignmentAckValidation(False, "unsupported ack object_version")
    if ack.get("assignment_id") != expected_assignment_id:
        return AssignmentAckValidation(False, "ack assignment_id mismatch")
    if ack.get("observer_node_id") != expected_observer_node_id:
        return AssignmentAckValidation(False, "ack observer_node_id mismatch")
    if ack.get("decision") not in ACK_DECISIONS:
        return AssignmentAckValidation(False, "invalid ack decision")
    if not isinstance(ack.get("signature"), str):
        return AssignmentAckValidation(False, "invalid ack signature encoding")
    if now.tzinfo is None or now.utcoffset() is None:
        return AssignmentAckValidation(False, "validation time must be timezone-aware")
    if (
        assignment_not_before.tzinfo is None
        or assignment_not_before.utcoffset() is None
        or assignment_expires_at.tzinfo is None
        or assignment_expires_at.utcoffset() is None
    ):
        return AssignmentAckValidation(False, "assignment time must be timezone-aware")
    try:
        acknowledged_at = _parse_time(ack["acknowledged_at"])
    except (TypeError, ValueError):
        return AssignmentAckValidation(False, "malformed ack time")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < acknowledged_at:
        return AssignmentAckValidation(False, "ack is from the future")
    if acknowledged_at + CLOCK_SKEW < assignment_not_before.astimezone(timezone.utc):
        return AssignmentAckValidation(False, "ack predates assignment")
    if acknowledged_at - CLOCK_SKEW > assignment_expires_at.astimezone(timezone.utc):
        return AssignmentAckValidation(False, "ack is after assignment expiry")
    if now_utc - CLOCK_SKEW > assignment_expires_at.astimezone(timezone.utc):
        return AssignmentAckValidation(False, "assignment has expired")
    if observer_credential.revoked:
        return AssignmentAckValidation(False, "observer credential is revoked")
    if (
        observer_credential.valid_until.tzinfo is None
        or observer_credential.valid_until.utcoffset() is None
        or observer_credential.valid_until.astimezone(timezone.utc) < now_utc
    ):
        return AssignmentAckValidation(False, "observer credential has expired")
    if not verify_message(
        observer_credential.public_key,
        assignment_ack_signing_payload(ack),
        ack["signature"],
    ):
        return AssignmentAckValidation(False, "invalid observer ack signature")
    return AssignmentAckValidation(True)


def _structural_error(assignment: Mapping[str, Any]) -> str | None:
    if set(assignment) != _ALL_FIELDS:
        return "invalid assignment fields"
    if assignment.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if assignment.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    try:
        if str(uuid.UUID(assignment["assignment_id"])) != assignment["assignment_id"]:
            return "invalid assignment_id"
    except (AttributeError, TypeError, ValueError):
        return "invalid assignment_id"
    subject = assignment.get("subject_node_id")
    if not isinstance(subject, str) or not subject.startswith(NODE_ID_PREFIX):
        return "invalid subject_node_id"
    observers = assignment.get("observer_node_ids")
    if (
        not isinstance(observers, list)
        or not 1 <= len(observers) <= 15
        or any(not isinstance(node_id, str) or not node_id.startswith(NODE_ID_PREFIX) for node_id in observers)
        or observers != sorted(set(observers))
        or subject in observers
    ):
        return "invalid observer_node_ids"
    if assignment.get("challenge_type") not in CHALLENGE_TYPES:
        return "invalid challenge_type"
    epoch = assignment.get("epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        return "invalid epoch"
    authority_epoch = assignment.get("authority_epoch")
    if (
        not isinstance(authority_epoch, int)
        or isinstance(authority_epoch, bool)
        or authority_epoch < 0
    ):
        return "invalid authority_epoch"
    if re.fullmatch(r"[0-9a-f]{64}", assignment.get("randomness_commitment", "")) is None:
        return "invalid randomness_commitment"
    committee = assignment.get("committee")
    if (
        not isinstance(committee, list)
        or not committee
        or any(not isinstance(node_id, str) or not node_id for node_id in committee)
        or committee != sorted(set(committee))
    ):
        return "invalid committee"
    threshold = assignment.get("threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        return "invalid threshold"
    previous_hash = assignment.get("previous_hash")
    if previous_hash is not None and (
        not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None
    ):
        return "invalid previous_hash"
    if not isinstance(assignment.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_challenge_assignment(
    assignment: Mapping[str, Any],
    *,
    now: datetime,
    expected_observer_node_ids: Sequence[str],
    expected_committee: Sequence[str],
    expected_threshold: int,
    validator_credentials: Mapping[str, ValidatorCredential],
    minimum_epoch: int = 0,
    expected_authority_epoch: int | None = None,
    expected_randomness_commitment: str | None = None,
) -> AssignmentValidation:
    if not isinstance(assignment, Mapping):
        return AssignmentValidation(False, "assignment must be an object")
    error = _structural_error(assignment)
    if error:
        return AssignmentValidation(False, error)
    if assignment["observer_node_ids"] != sorted(set(expected_observer_node_ids)):
        return AssignmentValidation(False, "observer set does not match external selection")
    if assignment["committee"] != sorted(set(expected_committee)):
        return AssignmentValidation(False, "committee does not match authority state")
    if assignment["threshold"] != expected_threshold:
        return AssignmentValidation(False, "threshold does not match authority policy")
    if (
        expected_authority_epoch is not None
        and assignment["authority_epoch"] != expected_authority_epoch
    ):
        return AssignmentValidation(False, "authority epoch does not match authority state")
    if (
        expected_randomness_commitment is not None
        and assignment["randomness_commitment"] != expected_randomness_commitment
    ):
        return AssignmentValidation(False, "randomness checkpoint mismatch")
    if assignment["epoch"] < minimum_epoch:
        return AssignmentValidation(False, "challenge assignment rollback detected")
    if now.tzinfo is None or now.utcoffset() is None:
        return AssignmentValidation(False, "validation time must be timezone-aware")
    try:
        not_before = _parse_time(assignment["not_before"])
        expires_at = _parse_time(assignment["expires_at"])
    except (TypeError, ValueError):
        return AssignmentValidation(False, "malformed assignment time")
    lifetime = expires_at - not_before
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return AssignmentValidation(False, "invalid assignment lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + CLOCK_SKEW < not_before:
        return AssignmentValidation(False, "assignment is not yet valid")
    if now_utc - CLOCK_SKEW > expires_at:
        return AssignmentValidation(False, "assignment has expired")

    payload = assignment_signing_payload(assignment)
    seen = set()
    valid_count = 0
    for entry in assignment["signatures"]:
        if not isinstance(entry, dict) or set(entry) != {"validator_id", "signature"}:
            return AssignmentValidation(False, "malformed validator signature", valid_count)
        validator_id = entry["validator_id"]
        if validator_id in seen:
            return AssignmentValidation(False, "duplicate validator signature", valid_count)
        seen.add(validator_id)
        if validator_id not in assignment["committee"]:
            return AssignmentValidation(False, "signature outside committee", valid_count)
        credential = validator_credentials.get(validator_id)
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
    if valid_count < expected_threshold:
        return AssignmentValidation(
            False, "insufficient valid validator signatures", valid_count
        )
    return AssignmentValidation(True, valid_signatures=valid_count)
