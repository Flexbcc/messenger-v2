"""OUO Capability Certificate v1 reference implementation."""

import base64
import copy
import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-capability/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/CAPABILITY_CERT/v1\x00"
MAX_LIFETIME = timedelta(days=30)
MAX_CLOCK_SKEW = timedelta(minutes=5)

CAPABILITY_MIN_LEVEL = {
    "home": 0,
    "relay": 2,
    "storage": 4,
    "gateway": 4,
    "turn": 4,
    "discovery": 4,
    "validator": 5,
}
ALLOWED_QUOTAS = frozenset(
    {
        "max_bandwidth_bps",
        "max_connections",
        "max_cells_per_epoch",
        "max_cover_bytes_per_epoch",
        "max_storage_bytes",
    }
)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "certificate_id",
    "subject_node_id",
    "level",
    "capabilities",
    "quotas",
    "epoch",
    "authority_epoch",
    "issued_at",
    "valid_until",
    "committee",
    "threshold",
    "previous_hash",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class ValidatorCredential:
    public_key: str
    valid_until: datetime
    revoked: bool = False


@dataclass(frozen=True)
class CapabilityValidation:
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
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def capability_signing_payload(certificate: Mapping[str, Any]) -> bytes:
    signed = {key: certificate[key] for key in _SIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(signed).encode("utf-8")


def capability_certificate_hash(certificate: Mapping[str, Any]) -> str:
    return hashlib.sha256(
        canonical_json(dict(certificate)).encode("utf-8")
    ).hexdigest()


def build_capability_certificate(
    *,
    subject_node_id: str,
    level: int,
    capabilities: Sequence[str],
    quotas: Mapping[str, int],
    epoch: int,
    authority_epoch: int | None = None,
    issued_at: datetime,
    valid_until: datetime,
    committee: Sequence[str],
    threshold: int,
    previous_hash: Optional[str] = None,
    certificate_id: Optional[str] = None,
) -> dict[str, Any]:
    issued_text = _utc_iso(issued_at)
    valid_text = _utc_iso(valid_until)
    if valid_until.astimezone(timezone.utc) - issued_at.astimezone(timezone.utc) > MAX_LIFETIME:
        raise ValueError("capability certificate lifetime exceeds 30 days")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "certificate_id": certificate_id or str(uuid.uuid4()),
        "subject_node_id": subject_node_id,
        "level": level,
        "capabilities": sorted(capabilities),
        "quotas": dict(sorted(quotas.items())),
        "epoch": epoch,
        "authority_epoch": epoch if authority_epoch is None else authority_epoch,
        "issued_at": issued_text,
        "valid_until": valid_text,
        "committee": sorted(committee),
        "threshold": threshold,
        "previous_hash": previous_hash,
        "signatures": [],
    }


def add_validator_signature(
    certificate: Mapping[str, Any],
    *,
    validator_id: str,
    validator_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(certificate))
    result.setdefault("signatures", []).append(
        {
            "validator_id": validator_id,
            "signature": sign_message(validator_signing_key, capability_signing_payload(result)),
        }
    )
    return result


def _structural_error(certificate: Mapping[str, Any]) -> Optional[str]:
    if set(certificate) != _ALL_FIELDS:
        return "invalid certificate fields"
    if certificate.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported protocol_version"
    if certificate.get("object_version") != OBJECT_VERSION:
        return "unsupported object_version"
    try:
        if str(uuid.UUID(certificate["certificate_id"])) != certificate["certificate_id"]:
            return "invalid certificate_id"
    except (AttributeError, TypeError, ValueError):
        return "invalid certificate_id"
    subject = certificate.get("subject_node_id")
    if not isinstance(subject, str) or not subject.startswith(NODE_ID_PREFIX):
        return "invalid subject_node_id"
    level = certificate.get("level")
    if not isinstance(level, int) or isinstance(level, bool) or not 0 <= level <= 5:
        return "invalid level"
    capabilities = certificate.get("capabilities")
    if (
        not isinstance(capabilities, list)
        or any(not isinstance(capability, str) for capability in capabilities)
        or capabilities != sorted(set(capabilities))
        or any(capability not in CAPABILITY_MIN_LEVEL for capability in capabilities)
    ):
        return "invalid capabilities"
    if any(level < CAPABILITY_MIN_LEVEL[capability] for capability in capabilities):
        return "level is not eligible for requested capability"
    quotas = certificate.get("quotas")
    if not isinstance(quotas, dict) or not set(quotas).issubset(ALLOWED_QUOTAS):
        return "invalid quotas"
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in quotas.values()):
        return "invalid quota value"
    epoch = certificate.get("epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        return "invalid epoch"
    authority_epoch = certificate.get("authority_epoch")
    if (
        not isinstance(authority_epoch, int)
        or isinstance(authority_epoch, bool)
        or authority_epoch < 0
    ):
        return "invalid authority_epoch"
    committee = certificate.get("committee")
    if (
        not isinstance(committee, list)
        or any(not isinstance(validator_id, str) or not validator_id for validator_id in committee)
        or committee != sorted(set(committee))
        or not committee
    ):
        return "invalid committee"
    threshold = certificate.get("threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        return "invalid threshold"
    previous_hash = certificate.get("previous_hash")
    if previous_hash is not None and (
        not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None
    ):
        return "invalid previous_hash"
    if not isinstance(certificate.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_capability_certificate(
    certificate: Mapping[str, Any],
    *,
    now: datetime,
    expected_committee: Sequence[str],
    expected_threshold: int,
    validator_credentials: Mapping[str, ValidatorCredential],
    minimum_epoch: int = 0,
    expected_authority_epoch: int | None = None,
    expected_subject_node_id: Optional[str] = None,
) -> CapabilityValidation:
    if not isinstance(certificate, Mapping):
        return CapabilityValidation(False, "certificate must be an object")
    error = _structural_error(certificate)
    if error:
        return CapabilityValidation(False, error)
    if now.tzinfo is None or now.utcoffset() is None:
        return CapabilityValidation(False, "validation time must be timezone-aware")
    if certificate["committee"] != sorted(set(expected_committee)):
        return CapabilityValidation(False, "committee does not match externally selected committee")
    if certificate["threshold"] != expected_threshold:
        return CapabilityValidation(False, "threshold does not match authority policy")
    if expected_subject_node_id and certificate["subject_node_id"] != expected_subject_node_id:
        return CapabilityValidation(False, "capability subject does not match Node Identity")
    if certificate["epoch"] < minimum_epoch:
        return CapabilityValidation(False, "capability certificate rollback detected")
    if (
        expected_authority_epoch is not None
        and certificate["authority_epoch"] != expected_authority_epoch
    ):
        return CapabilityValidation(False, "capability authority_epoch mismatch")

    try:
        issued_at = _parse_time(certificate["issued_at"])
        valid_until = _parse_time(certificate["valid_until"])
    except (TypeError, ValueError):
        return CapabilityValidation(False, "malformed certificate time")
    lifetime = valid_until - issued_at
    if lifetime <= timedelta(0) or lifetime > MAX_LIFETIME:
        return CapabilityValidation(False, "invalid certificate lifetime")
    now_utc = now.astimezone(timezone.utc)
    if now_utc + MAX_CLOCK_SKEW < issued_at:
        return CapabilityValidation(False, "certificate is not yet valid")
    if now_utc - MAX_CLOCK_SKEW > valid_until:
        return CapabilityValidation(False, "certificate has expired")

    payload = capability_signing_payload(certificate)
    seen: set[str] = set()
    valid_count = 0
    for entry in certificate["signatures"]:
        if not isinstance(entry, dict) or set(entry) != {"validator_id", "signature"}:
            return CapabilityValidation(False, "malformed validator signature", valid_count)
        validator_id = entry["validator_id"]
        if not isinstance(validator_id, str) or not isinstance(entry["signature"], str):
            return CapabilityValidation(False, "malformed validator signature", valid_count)
        if validator_id in seen:
            return CapabilityValidation(False, "duplicate validator signature", valid_count)
        seen.add(validator_id)
        if validator_id not in certificate["committee"]:
            return CapabilityValidation(False, "signature from validator outside committee", valid_count)
        credential = validator_credentials.get(validator_id)
        if credential is None:
            continue
        if credential.revoked:
            continue
        if credential.valid_until.tzinfo is None or credential.valid_until.utcoffset() is None:
            continue
        if credential.valid_until.astimezone(timezone.utc) < now_utc:
            continue
        if verify_message(credential.public_key, payload, entry["signature"]):
            valid_count += 1

    if valid_count < expected_threshold:
        return CapabilityValidation(False, "insufficient valid validator signatures", valid_count)
    return CapabilityValidation(True, valid_signatures=valid_count)
