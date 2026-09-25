"""Operational identity/state admission shared by register and heartbeat."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.config import NODE_IDENTITY_MODE, OPERATIONAL_CREDENTIAL_STATE_MODE
from app.network_guard import get_network_view_guard
from app.operational_credential_revocation_store import (
    require_operational_credential_not_revoked,
)
from app.operational_credential_store import (
    OperationalCredentialConflict,
    OperationalCredentialRollback,
    publish_operational_credential_state,
)
from app.trust_admission import require_node_trust_active
from shared.security.operational_credential_state import (
    validate_operational_credential_state,
)


def require_valid_identity(
    identity_report: Any,
    operational_certificate: Mapping[str, Any] | None,
    *,
    context: str,
) -> None:
    if NODE_IDENTITY_MODE == "enforce" and identity_report.status != "valid":
        suffix = f" for {context}" if context == "heartbeat" else ""
        raise HTTPException(
            status_code=403,
            detail=(
                f"valid Node Identity required{suffix}: "
                f"{identity_report.detail or identity_report.status}"
            ),
        )
    if identity_report.status == "valid" and operational_certificate is not None:
        now = datetime.now(timezone.utc)
        require_node_trust_active(identity_report.identity_node_id, at_time=now)
        require_operational_credential_not_revoked(
            operational_certificate,
            at_time=now,
        )


def validate_credential_state(
    state: Mapping[str, Any] | None,
    operational_certificate: Mapping[str, Any] | None,
    *,
    expected_node_id: str | None,
    context: str,
) -> Mapping[str, Any] | None:
    if OPERATIONAL_CREDENTIAL_STATE_MODE == "enforce" and state is None:
        raise HTTPException(
            status_code=403,
            detail=f"Operational Credential state is required for {context}",
        )
    if state is None:
        return None
    if (
        operational_certificate is None
        or state.get("operational_certificate") != operational_certificate
    ):
        raise HTTPException(
            status_code=403,
            detail=f"{context} certificate does not match credential state",
        )
    result = validate_operational_credential_state(
        state,
        now=datetime.now(timezone.utc),
        expected_node_id=expected_node_id,
        require_current_certificate=True,
    )
    if not result.valid:
        raise HTTPException(
            status_code=403,
            detail=f"invalid {context} Operational Credential state: {result.reason}",
        )
    return state


def publish_credential_state(state: Mapping[str, Any] | None, *, connection) -> None:
    if state is None:
        return
    try:
        publish_operational_credential_state(
            state,
            connection=connection,
            require_known_subject=True,
        )
    except OperationalCredentialConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting root-signed Operational Credential states detected"
        )
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except OperationalCredentialRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
