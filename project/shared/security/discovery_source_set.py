"""Bootstrap validation for the independently certified Discovery source set."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping

from shared.security.capability_certificate import (
    ValidatorCredential,
    validate_capability_certificate,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.node_identity import validate_operational_certificate


PROTOCOL_VERSION = "ouo-discovery-source-set/1"
MAX_SOURCE_SET_BYTES = 262144
MAX_SOURCES = 16


def parse_discovery_source_credentials(
    data: Mapping[str, Any],
    *,
    authority_state: CapabilityAuthorityState,
    now: datetime,
) -> dict[str, ValidatorCredential]:
    if not isinstance(data, Mapping) or set(data) != {
        "protocol_version",
        "authority_epoch",
        "sources",
    }:
        raise ValueError("invalid Discovery source set fields")
    if data.get("protocol_version") != PROTOCOL_VERSION:
        raise ValueError("unsupported Discovery source set protocol_version")
    if data.get("authority_epoch") != authority_state.epoch:
        raise ValueError("Discovery source set authority epoch mismatch")
    sources = data.get("sources")
    if not isinstance(sources, list) or not 1 <= len(sources) <= MAX_SOURCES:
        raise ValueError("Discovery source set must contain 1-16 sources")
    result: dict[str, ValidatorCredential] = {}
    for source in sources:
        if not isinstance(source, Mapping) or set(source) != {
            "operational_certificate",
            "capability_certificate",
        }:
            raise ValueError("invalid Discovery source entry")
        operational = source["operational_certificate"]
        capability = source["capability_certificate"]
        operational_validation = validate_operational_certificate(operational, now=now)
        if not operational_validation.valid:
            raise ValueError(
                f"invalid Discovery Operational Certificate: {operational_validation.reason}"
            )
        node_id = operational["node_id"]
        if node_id in result:
            raise ValueError("duplicate Discovery source NodeID")
        capability_validation = validate_capability_certificate(
            capability,
            now=now,
            expected_committee=authority_state.committee,
            expected_threshold=authority_state.threshold,
            validator_credentials=authority_state.validators,
            minimum_epoch=0,
            expected_authority_epoch=authority_state.epoch,
            expected_subject_node_id=node_id,
        )
        if not capability_validation.valid:
            raise ValueError(
                f"invalid Discovery CapabilityCertificate: {capability_validation.reason}"
            )
        if "discovery" not in capability["capabilities"]:
            raise ValueError("Discovery source lacks discovery capability")
        valid_until = datetime.fromisoformat(
            operational["valid_until"][:-1] + "+00:00"
            if operational["valid_until"].endswith("Z")
            else operational["valid_until"]
        )
        result[node_id] = ValidatorCredential(
            public_key=operational["operational_public_key"],
            valid_until=valid_until,
        )
    return result


def load_discovery_source_credentials(
    path: str,
    *,
    authority_state: CapabilityAuthorityState,
    now: datetime,
) -> dict[str, ValidatorCredential]:
    if not path:
        raise ValueError("Discovery source set path is required")
    raw = Path(path).read_bytes()
    if len(raw) > MAX_SOURCE_SET_BYTES:
        raise ValueError("Discovery source set exceeds size limit")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("Discovery source set is not valid JSON") from exc
    return parse_discovery_source_credentials(
        data,
        authority_state=authority_state,
        now=now,
    )
