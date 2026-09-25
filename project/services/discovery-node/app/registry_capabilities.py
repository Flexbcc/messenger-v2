"""Capability-certificate admission shared by node registry endpoints."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable, Mapping

from fastapi import HTTPException

from app.authority_checkpoint_store import load_effective_authority_state
from app.config import CAPABILITY_AUTHORITY_STATE_PATH, CAPABILITY_CERTIFICATE_MODE
from app.network_guard import require_governance_available
from app.registry_eligibility import INFRASTRUCTURE_CAPABILITIES
from shared.security.capability_enrollment import (
    evaluate_capability_report,
    load_capability_authority_state,
)


def evaluate_registry_capability(
    certificate: Mapping[str, Any] | None,
    *,
    identity_node_id: str | None,
    minimum_epoch: int,
    existing_certificate_json: str | None,
    advertised_capabilities: Iterable[str],
    context: str,
):
    try:
        authority_state = load_effective_authority_state(
            CAPABILITY_AUTHORITY_STATE_PATH,
            bootstrap_state=load_capability_authority_state(
                CAPABILITY_AUTHORITY_STATE_PATH
            ),
        )
        authority_error = None
    except ValueError as exc:
        authority_state = None
        authority_error = str(exc)

    report = evaluate_capability_report(
        certificate,
        mode=CAPABILITY_CERTIFICATE_MODE,
        now=datetime.now(timezone.utc),
        identity_node_id=identity_node_id,
        authority_state=authority_state,
        minimum_epoch=minimum_epoch,
        existing_certificate_json=existing_certificate_json,
    )
    if authority_error and certificate is not None:
        report = report.__class__(
            "unverifiable", f"invalid local authority state: {authority_error}"
        )

    if CAPABILITY_CERTIFICATE_MODE != "enforce":
        return report

    advertised = set(advertised_capabilities)
    infrastructure = advertised & INFRASTRUCTURE_CAPABILITIES
    if infrastructure and report.status != "valid":
        suffix = " for infrastructure roles" if context == "registration" else ""
        raise HTTPException(
            status_code=403,
            detail=(
                f"valid CapabilityCertificate required{suffix}"
                f"{' for heartbeat' if context == 'heartbeat' else ''}: "
                f"{report.detail or report.status}"
            ),
        )

    certified = set(report.certified_capabilities) if report.status == "valid" else set()
    permitted = certified | ({"home"} if context == "registration" else set())
    compared = advertised if context == "registration" else infrastructure
    if report.status == "valid" and not compared.issubset(permitted):
        raise HTTPException(
            status_code=403,
            detail=(
                "advertised capabilities exceed certified capabilities"
                if context == "registration"
                else "heartbeat capabilities exceed certified capabilities"
            ),
        )
    if context == "registration" and infrastructure:
        require_governance_available()
    return report
