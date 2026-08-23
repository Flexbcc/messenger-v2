"""Shared node-wide TrustRecord admission policy for Discovery control plane."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import HTTPException

from app.config import TRUST_LEDGER_DB_PATH, TRUST_LEDGER_MODE
from shared.security.trust_ledger import TrustLedgerStore


DENY_ACTIONS = frozenset({"suspension", "revocation"})


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("TrustRecord decision time must include timezone")
    return parsed.astimezone(timezone.utc)


def node_trust_denial_at(
    node_id: str, *, at_time: datetime, ledger_path: str | None = None
) -> dict | None:
    """Return the first effective terminal deny decision for ``node_id``.

    v1 has no quorum reinstatement action.  Therefore a later promotion record
    cannot silently erase an earlier suspension/revocation.  Historical events
    from before ``decided_at`` remain independently verifiable.
    """
    if TRUST_LEDGER_MODE != "enforce":
        return None
    if at_time.tzinfo is None or at_time.utcoffset() is None:
        raise ValueError("admission time must be timezone-aware")
    instant = at_time.astimezone(timezone.utc)
    denial = None
    for record in TrustLedgerStore(ledger_path or TRUST_LEDGER_DB_PATH).records(node_id):
        try:
            decided_at = _parse_time(record["decided_at"])
        except (KeyError, TypeError, ValueError) as exc:
            # Stored records are validated before append. Corrupt local state
            # is a fail-closed server fault, never an allow decision.
            raise HTTPException(
                status_code=503, detail="invalid local TrustRecord state"
            ) from exc
        if decided_at > instant:
            continue
        action = record.get("action")
        if action in DENY_ACTIONS:
            denial = record
        elif (
            action == "reinstatement"
            and denial is not None
            and denial.get("action") == "suspension"
        ):
            # Ledger validation guarantees this follows suspension, never
            # terminal revocation.
            denial = None
    return denial


def require_node_trust_active(node_id: str, *, at_time: datetime) -> None:
    denial = node_trust_denial_at(node_id, at_time=at_time)
    if denial is not None:
        raise HTTPException(
            status_code=403,
            detail=f"node is {denial['action']} by quorum TrustRecord",
        )
