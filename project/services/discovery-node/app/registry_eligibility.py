"""Current-certificate eligibility checks for public Discovery registry views."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from app.authority_checkpoint_store import load_effective_authority_state
from app.config import (
    CAPABILITY_AUTHORITY_STATE_PATH,
    CAPABILITY_CERTIFICATE_MODE,
    NODE_ADVERTISEMENT_MODE,
)
from app.registry_views import row_field
from shared.security.capability_enrollment import (
    evaluate_capability_report,
    load_capability_authority_state,
)
from shared.security.node_advertisement_enrollment import (
    evaluate_node_advertisement_report,
)


INFRASTRUCTURE_CAPABILITIES = frozenset(
    {"relay", "storage", "discovery", "gateway", "turn", "media", "validator"}
)
MAX_CAPABILITIES_PER_NODE = 32


def capabilities_from_row(row: object) -> tuple[str, ...] | None:
    try:
        raw = json.loads(row_field(row, "capabilities", "[]"))
    except (TypeError, ValueError):
        return None
    if not isinstance(raw, list) or len(raw) > MAX_CAPABILITIES_PER_NODE:
        return None
    capabilities = tuple(
        item for item in raw if isinstance(item, str) and 0 < len(item) <= 64
    )
    if len(capabilities) != len(raw):
        return None
    return capabilities


def row_has_current_advertisement(row: object) -> bool:
    raw = row_field(row, "node_advertisement")
    if not raw:
        return False
    try:
        advertisement = json.loads(raw)
    except (TypeError, ValueError):
        return False
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=datetime.now(timezone.utc),
        identity_node_id=row_field(row, "identity_node_id"),
        advertised_node_url=row_field(row, "node_url", ""),
        minimum_epoch=row_field(row, "node_advertisement_epoch", 0),
        existing_advertisement_json=raw,
    )
    return report.status == "valid"


def row_has_current_capability(row: object) -> bool:
    capabilities = capabilities_from_row(row)
    if capabilities is None:
        return False
    requested = set(capabilities)
    requested_infrastructure = requested & INFRASTRUCTURE_CAPABILITIES
    if not requested_infrastructure:
        return True

    raw = row_field(row, "capability_certificate")
    if not raw:
        return False
    try:
        certificate = json.loads(raw)
        authority_state = load_effective_authority_state(
            CAPABILITY_AUTHORITY_STATE_PATH,
            bootstrap_state=load_capability_authority_state(
                CAPABILITY_AUTHORITY_STATE_PATH
            ),
        )
    except (TypeError, ValueError):
        return False
    report = evaluate_capability_report(
        certificate,
        mode="report",
        now=datetime.now(timezone.utc),
        identity_node_id=row_field(row, "identity_node_id"),
        authority_state=authority_state,
        minimum_epoch=row_field(row, "capability_epoch", 0),
        existing_certificate_json=raw,
    )
    return report.status == "valid" and requested_infrastructure.issubset(
        set(report.certified_capabilities)
    )


def row_is_publicly_eligible(row: object) -> bool:
    if NODE_ADVERTISEMENT_MODE == "enforce" and not row_has_current_advertisement(
        row
    ):
        return False
    if CAPABILITY_CERTIFICATE_MODE == "enforce" and not row_has_current_capability(
        row
    ):
        return False
    return row_field(row, "quarantine_action", "off") != "isolate"
