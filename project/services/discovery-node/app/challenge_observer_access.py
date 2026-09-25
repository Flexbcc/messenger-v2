"""Authorization policy for registered and portable challenge observers."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone

from fastapi import HTTPException

from app.config import TRUST_LEDGER_DB_PATH
from app.security import verify_hash
from app.trust import enrollment_required
from app.trust_admission import node_trust_denial_at
from shared.security.jwt_auth import extract_bearer_token


def _require_node_id(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 256
        or any(ord(character) < 33 or ord(character) == 127 for character in value)
    ):
        raise HTTPException(status_code=400, detail="invalid observer NodeID")
    return value


def require_registered_observer(
    conn: sqlite3.Connection,
    observer_node_id: str,
    authorization: str | None,
):
    observer_node_id = _require_node_id(observer_node_id)
    observer = conn.execute(
        "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
        (observer_node_id,),
    ).fetchone()
    if observer is None or observer["node_identity_status"] != "valid":
        raise HTTPException(status_code=403, detail="unknown observer Node Identity")
    if (observer["trust_status"] or "unknown") != "trusted":
        raise HTTPException(status_code=403, detail="observer is not trusted")
    if observer["node_token_hash"] and enrollment_required():
        token = extract_bearer_token(authorization) or ""
        if not verify_hash(token, observer["node_token_hash"]):
            raise HTTPException(
                status_code=401,
                detail="invalid or missing observer node_token",
            )
    return observer


def require_portable_observer_allowed(
    conn: sqlite3.Connection,
    observer_node_id: str,
    *,
    at_time: datetime | None = None,
    historical_event: bool = False,
    policy_time: datetime | None = None,
) -> None:
    observer_node_id = _require_node_id(observer_node_id)
    local = conn.execute(
        "SELECT trust_status FROM node_capabilities WHERE identity_node_id = ?",
        (observer_node_id,),
    ).fetchone()
    instant = at_time or datetime.now(timezone.utc)
    denial = node_trust_denial_at(
        observer_node_id,
        at_time=instant,
        ledger_path=TRUST_LEDGER_DB_PATH,
    )
    current_denial = node_trust_denial_at(
        observer_node_id,
        at_time=policy_time or datetime.now(timezone.utc),
        ledger_path=TRUST_LEDGER_DB_PATH,
    )
    historical_before_denial = False
    if historical_event and denial is None and current_denial is not None:
        try:
            decided_at = current_denial["decided_at"]
            if not isinstance(decided_at, str):
                raise ValueError("invalid trust decision time")
            parsed_decision = datetime.fromisoformat(
                decided_at[:-1] + "+00:00"
                if decided_at.endswith("Z")
                else decided_at
            )
            if parsed_decision.tzinfo is None or parsed_decision.utcoffset() is None:
                raise ValueError("trust decision time must include timezone")
            historical_before_denial = parsed_decision.astimezone(timezone.utc) > instant
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(
                status_code=503,
                detail="invalid local TrustRecord state",
            ) from exc
    if denial is not None:
        raise HTTPException(status_code=403, detail="observer is suspended or revoked")
    if (
        local is not None
        and (local["trust_status"] or "unknown") != "trusted"
        and not historical_before_denial
    ):
        raise HTTPException(status_code=403, detail="observer is not trusted")
