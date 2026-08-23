"""Quorum-signed revocation of one OUO Operational Certificate.

This object deliberately does not revoke the Node Root, NodeID, trust level, or
capabilities.  It only stops one certificate serial/key from being admitted at
and after ``effective_at``.  Version 1 forbids retroactive effective times so
already accepted historical evidence has deterministic validity.
"""

from __future__ import annotations

import copy
import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import (
    NODE_ID_PREFIX,
    validate_operational_certificate,
)


PROTOCOL_VERSION = "ouo-operational-credential-revocation/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/OPERATIONAL_CREDENTIAL_REVOCATION/v1\x00"
GENESIS_DOMAIN = b"OUO/OPERATIONAL_CREDENTIAL_REVOCATION_GENESIS/v1\x00"
CLOCK_SKEW = timedelta(minutes=5)
MAX_REVOCATION_BYTES = 64 * 1024

_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "revocation_id",
    "node_id",
    "revocation_epoch",
    "credential_epoch",
    "certificate_serial",
    "operational_public_key",
    "certificate_hash",
    "authority_epoch",
    "previous_hash",
    "reason_commitment",
    "effective_at",
    "decided_at",
    "committee",
    "threshold",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class OperationalCredentialRevocationValidation:
    valid: bool
    reason: Optional[str] = None
    valid_signatures: int = 0


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


def operational_certificate_hash(certificate: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        canonical_json(dict(certificate)).encode("utf-8")
    ).hexdigest()


def operational_credential_revocation_genesis_hash(node_id: str) -> str:
    if not isinstance(node_id, str) or not node_id.startswith(NODE_ID_PREFIX):
        raise ValueError("invalid NodeID")
    return hashlib.sha256(GENESIS_DOMAIN + node_id.encode("utf-8")).hexdigest()


def operational_credential_revocation_signing_payload(
    revocation: Mapping[str, Any],
) -> bytes:
    return SIGNING_DOMAIN + canonical_json(
        {field: revocation[field] for field in _SIGNED_FIELDS}
    ).encode("utf-8")


def operational_credential_revocation_hash(
    revocation: Mapping[str, Any],
) -> str:
    return hashlib.sha256(
        canonical_json(dict(revocation)).encode("utf-8")
    ).hexdigest()


def build_operational_credential_revocation(
    *,
    operational_certificate: Mapping[str, Any],
    credential_epoch: int,
    revocation_epoch: int,
    authority_epoch: int,
    reason_commitment: str,
    committee: Sequence[str],
    threshold: int,
    decided_at: datetime,
    previous_hash: Optional[str] = None,
    revocation_id: Optional[str] = None,
) -> dict[str, Any]:
    node_id = operational_certificate.get("node_id")
    if previous_hash is None:
        if revocation_epoch != 0:
            raise ValueError("non-genesis revocation requires previous_hash")
        previous_hash = operational_credential_revocation_genesis_hash(str(node_id))
    decided = _utc_iso(decided_at)
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "revocation_id": revocation_id or str(uuid.uuid4()),
        "node_id": node_id,
        "revocation_epoch": revocation_epoch,
        "credential_epoch": credential_epoch,
        "certificate_serial": operational_certificate.get("serial"),
        "operational_public_key": operational_certificate.get(
            "operational_public_key"
        ),
        "certificate_hash": operational_certificate_hash(operational_certificate),
        "authority_epoch": authority_epoch,
        "previous_hash": previous_hash,
        "reason_commitment": reason_commitment,
        # v1 intentionally has no retroactive revocation.
        "effective_at": decided,
        "decided_at": decided,
        "committee": sorted(committee),
        "threshold": threshold,
        "signatures": [],
    }


def add_operational_credential_revocation_signature(
    revocation: Mapping[str, Any],
    *,
    validator_id: str,
    validator_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(revocation))
    result.setdefault("signatures", []).append(
        {
            "validator_id": validator_id,
            "signature": sign_message(
                validator_signing_key,
                operational_credential_revocation_signing_payload(result),
            ),
        }
    )
    result["signatures"] = sorted(
        result["signatures"], key=lambda item: item["validator_id"]
    )
    return result


def _semantic_error(revocation: Mapping[str, Any]) -> Optional[str]:
    if set(revocation) != _ALL_FIELDS:
        return "invalid revocation fields"
    if revocation.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if revocation.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    try:
        if str(uuid.UUID(revocation["revocation_id"])) != revocation["revocation_id"]:
            return "invalid revocation_id"
        if str(uuid.UUID(revocation["certificate_serial"])) != revocation["certificate_serial"]:
            return "invalid certificate_serial"
    except (AttributeError, TypeError, ValueError):
        return "invalid revocation identifier"
    node_id = revocation.get("node_id")
    if not isinstance(node_id, str) or not node_id.startswith(NODE_ID_PREFIX):
        return "invalid node_id"
    for field in ("revocation_epoch", "credential_epoch", "authority_epoch"):
        value = revocation.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return f"invalid {field}"
    for field in ("certificate_hash", "previous_hash", "reason_commitment"):
        if not isinstance(revocation.get(field), str) or re.fullmatch(
            r"[0-9a-f]{64}", revocation[field]
        ) is None:
            return f"invalid {field}"
    if not isinstance(revocation.get("operational_public_key"), str):
        return "invalid operational_public_key"
    committee = revocation.get("committee")
    if (
        not isinstance(committee, list)
        or not committee
        or committee != sorted(set(committee))
        or any(not isinstance(item, str) or not item for item in committee)
    ):
        return "invalid committee"
    threshold = revocation.get("threshold")
    if (
        not isinstance(threshold, int)
        or isinstance(threshold, bool)
        or not 1 <= threshold <= len(committee)
    ):
        return "invalid threshold"
    if not isinstance(revocation.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_operational_credential_revocation(
    revocation: Mapping[str, Any],
    *,
    operational_certificate: Mapping[str, Any],
    now: datetime,
    expected_revocation_epoch: int,
    expected_previous_hash: str,
    expected_committee: Sequence[str],
    expected_threshold: int,
    validator_credentials: Mapping[str, ValidatorCredential],
    expected_authority_epoch: int,
) -> OperationalCredentialRevocationValidation:
    if not isinstance(revocation, Mapping):
        return OperationalCredentialRevocationValidation(
            False, "revocation must be an object"
        )
    try:
        if len(canonical_json(dict(revocation)).encode("utf-8")) > MAX_REVOCATION_BYTES:
            return OperationalCredentialRevocationValidation(
                False, "revocation exceeds size limit"
            )
    except (TypeError, ValueError):
        return OperationalCredentialRevocationValidation(
            False, "revocation is not valid JSON"
        )
    error = _semantic_error(revocation)
    if error:
        return OperationalCredentialRevocationValidation(False, error)
    if revocation["revocation_epoch"] != expected_revocation_epoch:
        return OperationalCredentialRevocationValidation(
            False, "unexpected revocation_epoch"
        )
    if revocation["previous_hash"] != expected_previous_hash:
        return OperationalCredentialRevocationValidation(
            False, "revocation chain mismatch"
        )
    if revocation["authority_epoch"] != expected_authority_epoch:
        return OperationalCredentialRevocationValidation(
            False, "authority epoch mismatch"
        )
    if revocation["committee"] != sorted(set(expected_committee)):
        return OperationalCredentialRevocationValidation(
            False, "committee does not match authority state"
        )
    if revocation["threshold"] != expected_threshold:
        return OperationalCredentialRevocationValidation(
            False, "threshold does not match authority policy"
        )
    try:
        if (
            operational_certificate_hash(operational_certificate)
            != revocation["certificate_hash"]
            or operational_certificate.get("node_id") != revocation["node_id"]
            or operational_certificate.get("serial")
            != revocation["certificate_serial"]
            or operational_certificate.get("operational_public_key")
            != revocation["operational_public_key"]
        ):
            return OperationalCredentialRevocationValidation(
                False, "revocation does not match Operational Certificate"
            )
        issued_at = _parse_time(operational_certificate.get("issued_at"))
    except (TypeError, ValueError):
        return OperationalCredentialRevocationValidation(
            False, "invalid Operational Certificate"
        )
    certificate_validation = validate_operational_certificate(
        operational_certificate, now=issued_at, clock_skew=timedelta(0)
    )
    if not certificate_validation.valid:
        return OperationalCredentialRevocationValidation(
            False,
            f"invalid Operational Certificate: {certificate_validation.reason}",
        )
    if now.tzinfo is None or now.utcoffset() is None:
        return OperationalCredentialRevocationValidation(
            False, "validation time must be timezone-aware"
        )
    try:
        effective_at = _parse_time(revocation["effective_at"])
        decided_at = _parse_time(revocation["decided_at"])
    except (TypeError, ValueError):
        return OperationalCredentialRevocationValidation(
            False, "malformed revocation time"
        )
    if effective_at != decided_at:
        return OperationalCredentialRevocationValidation(
            False, "v1 revocation cannot be retroactive or delayed"
        )
    if decided_at > now.astimezone(timezone.utc) + CLOCK_SKEW:
        return OperationalCredentialRevocationValidation(
            False, "revocation decision is from the future"
        )

    payload = operational_credential_revocation_signing_payload(revocation)
    seen: set[str] = set()
    valid_count = 0
    for entry in revocation["signatures"]:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"validator_id", "signature"}
            or not isinstance(entry["validator_id"], str)
            or not isinstance(entry["signature"], str)
        ):
            return OperationalCredentialRevocationValidation(
                False, "malformed validator signature", valid_count
            )
        validator_id = entry["validator_id"]
        if validator_id in seen:
            return OperationalCredentialRevocationValidation(
                False, "duplicate validator signature", valid_count
            )
        seen.add(validator_id)
        if validator_id not in revocation["committee"]:
            return OperationalCredentialRevocationValidation(
                False, "signature outside authority committee", valid_count
            )
        credential = validator_credentials.get(validator_id)
        if (
            credential is None
            or credential.revoked
            or credential.valid_until.tzinfo is None
            or credential.valid_until.utcoffset() is None
            or credential.valid_until.astimezone(timezone.utc) < decided_at
        ):
            continue
        if verify_message(credential.public_key, payload, entry["signature"]):
            valid_count += 1
    if valid_count < expected_threshold:
        return OperationalCredentialRevocationValidation(
            False, "insufficient valid validator signatures", valid_count
        )
    return OperationalCredentialRevocationValidation(
        True, valid_signatures=valid_count
    )
