"""Portable Operational-Key proof for Discovery observer requests."""

from __future__ import annotations

import copy
import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import validate_operational_certificate


PROTOCOL_VERSION = "ouo-observer-request-proof/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/OBSERVER_REQUEST_PROOF/v1\x00"
MAX_LIFETIME = timedelta(minutes=5)
CLOCK_SKEW = timedelta(minutes=2)
MAX_PROOF_BYTES = 32 * 1024
ALLOWED_ACTIONS = frozenset({"challenge_assignment_pull"})
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "observer_node_id",
    "action",
    "request_nonce",
    "issued_at",
    "expires_at",
    "payload_hash",
    "operational_certificate",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signature"}


@dataclass(frozen=True)
class ObserverProofValidation:
    valid: bool
    reason: str | None = None
    observer_node_id: str | None = None
    operational_public_key: str | None = None
    request_nonce: str | None = None


def _iso(value: datetime) -> str:
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


def observer_payload_hash(payload: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(payload)).encode("utf-8")).hexdigest()


def observer_proof_signing_payload(proof: Mapping[str, Any]) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: proof[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def issue_observer_request_proof(
    *,
    observer_signing_key: SigningKey,
    operational_certificate: Mapping[str, Any],
    action: str,
    payload: Mapping[str, Any],
    issued_at: datetime,
    expires_at: datetime,
    request_nonce: str | None = None,
) -> dict[str, Any]:
    proof = {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "observer_node_id": operational_certificate.get("node_id"),
        "action": action,
        "request_nonce": request_nonce or str(uuid.uuid4()),
        "issued_at": _iso(issued_at),
        "expires_at": _iso(expires_at),
        "payload_hash": observer_payload_hash(payload),
        "operational_certificate": copy.deepcopy(dict(operational_certificate)),
    }
    proof["signature"] = sign_message(
        observer_signing_key,
        observer_proof_signing_payload(proof),
    )
    return proof


def validate_observer_request_proof(
    proof: Mapping[str, Any],
    *,
    action: str,
    payload: Mapping[str, Any],
    now: datetime,
) -> ObserverProofValidation:
    if not isinstance(proof, Mapping) or set(proof) != _ALL_FIELDS:
        return ObserverProofValidation(False, "invalid observer proof fields")
    try:
        if len(canonical_json(dict(proof)).encode("utf-8")) > MAX_PROOF_BYTES:
            return ObserverProofValidation(False, "observer proof exceeds size limit")
    except (TypeError, ValueError):
        return ObserverProofValidation(False, "observer proof is not canonical JSON")
    if proof.get("protocol_version") != PROTOCOL_VERSION or proof.get("object_version") != OBJECT_VERSION:
        return ObserverProofValidation(False, "unsupported observer proof version")
    if action not in ALLOWED_ACTIONS or proof.get("action") != action:
        return ObserverProofValidation(False, "observer proof action mismatch")
    nonce = proof.get("request_nonce")
    try:
        if str(uuid.UUID(nonce)) != nonce:
            return ObserverProofValidation(False, "invalid observer proof nonce")
    except (AttributeError, TypeError, ValueError):
        return ObserverProofValidation(False, "invalid observer proof nonce")
    if re.fullmatch(r"[0-9a-f]{64}", proof.get("payload_hash", "")) is None:
        return ObserverProofValidation(False, "invalid observer payload hash")
    try:
        expected_hash = observer_payload_hash(payload)
    except (TypeError, ValueError):
        return ObserverProofValidation(False, "observer payload is not canonical JSON")
    if proof["payload_hash"] != expected_hash:
        return ObserverProofValidation(False, "observer proof payload mismatch")
    if now.tzinfo is None or now.utcoffset() is None:
        return ObserverProofValidation(False, "validation time must be timezone-aware")
    try:
        issued_at = _parse_time(proof["issued_at"])
        expires_at = _parse_time(proof["expires_at"])
    except (TypeError, ValueError):
        return ObserverProofValidation(False, "malformed observer proof time")
    now_utc = now.astimezone(timezone.utc)
    if expires_at <= issued_at or expires_at - issued_at > MAX_LIFETIME:
        return ObserverProofValidation(False, "invalid observer proof lifetime")
    if issued_at > now_utc + CLOCK_SKEW or expires_at < now_utc - CLOCK_SKEW:
        return ObserverProofValidation(False, "observer proof is outside validity window")
    certificate = proof.get("operational_certificate")
    validation = validate_operational_certificate(certificate, now=now_utc)
    if not validation.valid:
        return ObserverProofValidation(
            False,
            f"invalid observer operational certificate: {validation.reason}",
        )
    if proof.get("observer_node_id") != certificate.get("node_id"):
        return ObserverProofValidation(False, "observer proof NodeID mismatch")
    if not isinstance(proof.get("signature"), str) or not verify_message(
        certificate["operational_public_key"],
        observer_proof_signing_payload(proof),
        proof["signature"],
    ):
        return ObserverProofValidation(False, "invalid observer proof signature")
    return ObserverProofValidation(
        True,
        observer_node_id=certificate["node_id"],
        operational_public_key=certificate["operational_public_key"],
        request_nonce=nonce,
    )
