"""Capability Certificate evaluation for Discovery migration/enforcement."""

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping, Optional

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import (
    ValidatorCredential,
    capability_certificate_hash,
    validate_capability_certificate,
)


MAX_AUTHORITY_STATE_BYTES = 65536
MAX_CERTIFICATE_BYTES = 65536
SUPPORTED_MODES = frozenset({"off", "report", "enforce"})


@dataclass(frozen=True)
class CapabilityAuthorityState:
    epoch: int
    committee: tuple[str, ...]
    threshold: int
    validators: Mapping[str, ValidatorCredential]


@dataclass(frozen=True)
class CapabilityReport:
    status: str
    detail: Optional[str]
    certificate_json: Optional[str] = None
    certified_capabilities: tuple[str, ...] = ()
    certified_level: Optional[int] = None
    epoch: Optional[int] = None


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("validator valid_until must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("validator valid_until must include timezone")
    return parsed


def parse_capability_authority_state(data: Mapping[str, Any]) -> CapabilityAuthorityState:
    if set(data) != {"epoch", "committee", "threshold", "validators"}:
        raise ValueError("invalid authority state fields")
    epoch = data["epoch"]
    committee = data["committee"]
    threshold = data["threshold"]
    validators = data["validators"]
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("invalid authority epoch")
    if (
        not isinstance(committee, list)
        or any(not isinstance(item, str) or not item for item in committee)
        or committee != sorted(set(committee))
        or not committee
    ):
        raise ValueError("invalid authority committee")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        raise ValueError("invalid authority threshold")
    if not isinstance(validators, dict) or set(validators) != set(committee):
        raise ValueError("authority validators must exactly match committee")
    parsed_validators = {}
    for validator_id, value in validators.items():
        if not isinstance(value, dict) or set(value) != {"public_key", "valid_until", "revoked"}:
            raise ValueError("invalid validator credential")
        if not isinstance(value["public_key"], str) or not isinstance(value["revoked"], bool):
            raise ValueError("invalid validator credential")
        parsed_validators[validator_id] = ValidatorCredential(
            public_key=value["public_key"],
            valid_until=_parse_time(value["valid_until"]),
            revoked=value["revoked"],
        )
    return CapabilityAuthorityState(epoch, tuple(committee), threshold, parsed_validators)


def load_capability_authority_state(path: str) -> Optional[CapabilityAuthorityState]:
    if not path:
        return None
    authority_file = Path(path)
    try:
        raw = authority_file.read_bytes()
    except FileNotFoundError:
        return None
    if len(raw) > MAX_AUTHORITY_STATE_BYTES:
        raise ValueError("authority state exceeds size limit")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("authority state is not valid JSON") from exc
    if not isinstance(data, dict):
        raise ValueError("authority state must be an object")
    return parse_capability_authority_state(data)


def evaluate_capability_report(
    certificate: Optional[Mapping[str, Any]],
    *,
    mode: str,
    now: datetime,
    identity_node_id: Optional[str],
    authority_state: Optional[CapabilityAuthorityState],
    minimum_epoch: int = 0,
    existing_certificate_json: Optional[str] = None,
) -> CapabilityReport:
    if mode not in SUPPORTED_MODES:
        raise ValueError(f"unsupported CAPABILITY_CERTIFICATE_MODE: {mode}")
    if mode == "off":
        return CapabilityReport("skipped", None)
    if certificate is None:
        return CapabilityReport("absent", "capability certificate not provided")
    if not isinstance(certificate, Mapping):
        return CapabilityReport("invalid", "capability certificate must be an object")
    try:
        serialized = canonical_json(dict(certificate))
    except (TypeError, ValueError):
        return CapabilityReport("invalid", "capability certificate is not valid JSON")
    if len(serialized.encode("utf-8")) > MAX_CERTIFICATE_BYTES:
        return CapabilityReport("invalid", "capability certificate exceeds size limit")
    if identity_node_id is None:
        return CapabilityReport("unverifiable", "verified Node Identity is required")
    if authority_state is None:
        return CapabilityReport("unverifiable", "capability authority state is unavailable")
    validation = validate_capability_certificate(
        certificate,
        now=now,
        expected_committee=authority_state.committee,
        expected_threshold=authority_state.threshold,
        validator_credentials=authority_state.validators,
        minimum_epoch=minimum_epoch,
        expected_authority_epoch=authority_state.epoch,
        expected_subject_node_id=identity_node_id,
    )
    if not validation.valid:
        return CapabilityReport("invalid", validation.reason)
    if existing_certificate_json:
        try:
            existing = json.loads(existing_certificate_json)
        except (TypeError, json.JSONDecodeError):
            return CapabilityReport("invalid_state", "stored certificate is not valid JSON")
        if not isinstance(existing, dict):
            return CapabilityReport("invalid_state", "stored certificate is not an object")
        existing_epoch = existing.get("epoch")
        if certificate["epoch"] == existing_epoch:
            if dict(certificate) != existing:
                return CapabilityReport(
                    "equivocation",
                    "different CapabilityCertificates use the same subject epoch",
                )
        elif certificate["epoch"] != existing_epoch + 1:
            return CapabilityReport(
                "broken_chain",
                "CapabilityCertificate subject epoch must be consecutive",
            )
        elif certificate["previous_hash"] != capability_certificate_hash(existing):
            return CapabilityReport(
                "broken_chain",
                "CapabilityCertificate previous_hash does not match stored head",
            )
    return CapabilityReport(
        "valid",
        None,
        certificate_json=serialized,
        certified_capabilities=tuple(certificate["capabilities"]),
        certified_level=certificate["level"],
        epoch=certificate["epoch"],
    )
