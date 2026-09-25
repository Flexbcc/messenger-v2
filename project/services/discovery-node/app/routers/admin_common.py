"""Shared validation and audit helpers for Discovery admin routers."""

import sqlite3
from typing import Annotated

from fastapi import Header, HTTPException, Path, Request

from app.audit import log_admin_action
from app.db import get_conn

AdminNodeId = Annotated[
    str,
    Path(
        min_length=1,
        max_length=128,
        pattern=r"^[A-Za-z0-9._:-]+$",
    ),
]


def admin_actor(
    x_operator_id: str | None = Header(None, alias="X-Operator-Id"),
) -> str:
    value = (x_operator_id or "").strip() or "operator"
    if len(value) > 128 or any(
        ord(character) < 32 or ord(character) == 127 for character in value
    ):
        raise HTTPException(status_code=400, detail="invalid operator id")
    return value


def audit_reason(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    if len(normalized) > 1000 or any(
        ord(character) < 32 or ord(character) == 127 for character in normalized
    ):
        raise HTTPException(status_code=422, detail="invalid audit reason")
    return normalized


def client_ip(request: Request) -> str:
    """Return the authenticated transport peer used for audit attribution."""
    return request.client.host if request.client else "unknown"


def log_control_action(
    request: Request,
    *,
    actor: str,
    action: str,
    detail: str,
) -> None:
    with get_conn() as conn:
        log_control_action_on(
            conn,
            request,
            actor=actor,
            action=action,
            detail=detail,
        )
        conn.commit()


def log_control_action_on(
    conn: sqlite3.Connection,
    request: Request,
    *,
    actor: str,
    action: str,
    detail: str,
) -> None:
    log_admin_action(
        conn,
        actor=actor,
        action=action,
        node_id="control-plane",
        detail=detail,
        client_ip=client_ip(request),
    )
