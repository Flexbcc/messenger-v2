"""Persistent per-NodeID Operational Credential high-watermark chains."""

from __future__ import annotations

import json
import sqlite3
from contextlib import nullcontext
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from shared.security.canonical import canonical_json
from shared.security.operational_credential_state import (
    MAX_STATE_BYTES,
    operational_credential_state_hash,
    validate_operational_credential_state,
)


MAX_STATES_PER_NODE = 4096
MAX_FUTURE_SKEW = timedelta(minutes=5)


class OperationalCredentialConflict(RuntimeError):
    """The Node Root signed two different states for one credential epoch."""


class OperationalCredentialRollback(ValueError):
    """A valid but older state was offered after a higher local watermark."""


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    ).astimezone(timezone.utc)


def _latest_row(conn: sqlite3.Connection, node_id: str):
    return conn.execute(
        """SELECT node_id, credential_epoch, state_hash, previous_state_hash,
                  certificate_serial, certificate_issued_at, state_json, stored_at
           FROM operational_credential_states
           WHERE node_id = ? ORDER BY credential_epoch DESC LIMIT 1""",
        (node_id,),
    ).fetchone()


def operational_credential_head(node_id: str) -> dict[str, Any] | None:
    with get_conn() as conn:
        row = _latest_row(conn, node_id)
    if row is None:
        return None
    return {
        "state": json.loads(row["state_json"]),
        "state_hash": row["state_hash"],
        "stored_at": row["stored_at"],
    }


def operational_credential_latest_sequence() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(sequence), 0) FROM operational_credential_state_events"
        ).fetchone()
    return int(row[0])


def list_operational_credential_states(
    *,
    after_sequence: int = 0,
    limit: int = 100,
) -> list[dict[str, Any]]:
    if not isinstance(after_sequence, int) or isinstance(after_sequence, bool) or after_sequence < 0:
        raise ValueError("after_sequence must be non-negative")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT e.sequence, s.node_id, s.credential_epoch, s.state_hash,
                      s.state_json, s.stored_at
               FROM operational_credential_state_events e
               JOIN operational_credential_states s ON s.state_hash = e.state_hash
               WHERE e.sequence > ? ORDER BY e.sequence ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {
            "sequence": row["sequence"],
            "state": json.loads(row["state_json"]),
            "state_hash": row["state_hash"],
            "stored_at": row["stored_at"],
        }
        for row in rows
    ]


def _subject_is_known(conn: sqlite3.Connection, node_id: str) -> bool:
    registered = conn.execute(
        "SELECT 1 FROM node_capabilities WHERE identity_node_id = ? LIMIT 1",
        (node_id,),
    ).fetchone()
    if registered is not None:
        return True
    assigned = conn.execute(
        """SELECT 1 FROM challenge_assignment_observers
           WHERE observer_node_id = ? LIMIT 1""",
        (node_id,),
    ).fetchone()
    if assigned is not None:
        return True
    advertised = conn.execute(
        """SELECT 1 FROM node_advertisement_observations
           WHERE subject_node_id = ? LIMIT 1""",
        (node_id,),
    ).fetchone()
    return advertised is not None


def publish_operational_credential_state(
    state: Mapping[str, Any],
    *,
    now: datetime | None = None,
    require_known_subject: bool = True,
    connection: sqlite3.Connection | None = None,
) -> tuple[str, bool]:
    if not isinstance(state, Mapping):
        raise HTTPException(status_code=400, detail="credential state must be an object")
    try:
        serialized = canonical_json(dict(state))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="credential state must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_STATE_BYTES:
        raise HTTPException(status_code=413, detail="credential state exceeds size limit")
    try:
        digest = operational_credential_state_hash(state)
        node_id = state["node_id"]
        epoch = state["credential_epoch"]
        certificate = state["operational_certificate"]
        issued_at = _parse_time(certificate["issued_at"])
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid credential state") from exc
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if issued_at > current_time + MAX_FUTURE_SKEW:
        raise HTTPException(status_code=400, detail="credential state is from the future")

    owns_connection = connection is None
    connection_context = get_conn() if owns_connection else nullcontext(connection)
    with connection_context as conn:
        existing = None
        if isinstance(node_id, str) and isinstance(epoch, int) and not isinstance(epoch, bool):
            existing = conn.execute(
                """SELECT state_hash, previous_state_hash, state_json
                   FROM operational_credential_states
                   WHERE node_id = ? AND credential_epoch = ?""",
                (node_id, epoch),
            ).fetchone()
        if existing is not None:
            if existing["state_hash"] == digest and existing["state_json"] == serialized:
                return digest, False
            # Do not turn unauthenticated same-epoch junk into freeze evidence.
            # The conflicting Root-signed state is validated below first.
            expected_epoch = epoch
            expected_previous_hash = existing["previous_state_hash"]
            conflict_candidate = True
        else:
            conflict_candidate = False
        if require_known_subject and (
            not isinstance(node_id, str) or not _subject_is_known(conn, node_id)
        ):
            raise HTTPException(status_code=403, detail="unknown credential state subject")
        if not conflict_candidate:
            latest = _latest_row(conn, node_id) if isinstance(node_id, str) else None
            if latest is None:
                expected_epoch = 0
                expected_previous_hash = None
            else:
                if isinstance(epoch, int) and epoch <= latest["credential_epoch"]:
                    raise OperationalCredentialRollback(
                        "credential state is below the highest accepted epoch"
                    )
                expected_epoch = latest["credential_epoch"] + 1
                expected_previous_hash = latest["state_hash"]
        if expected_epoch >= MAX_STATES_PER_NODE:
            raise HTTPException(status_code=429, detail="credential state chain limit exceeded")
        validation = validate_operational_credential_state(
            state,
            now=current_time,
            expected_node_id=node_id if isinstance(node_id, str) else None,
            expected_epoch=expected_epoch,
            expected_previous_hash=expected_previous_hash,
            require_current_certificate=False,
        )
        if not validation.valid:
            raise HTTPException(
                status_code=400,
                detail=validation.reason or "invalid credential state",
            )
        if conflict_candidate:
            raise OperationalCredentialConflict(
                "conflicting Operational Credential state at the same epoch"
            )
        try:
            conn.execute(
                """INSERT INTO operational_credential_states (
                       node_id, credential_epoch, state_hash, previous_state_hash,
                       certificate_serial, certificate_issued_at, state_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    node_id,
                    epoch,
                    digest,
                    state["previous_state_hash"],
                    certificate["serial"],
                    certificate["issued_at"],
                    serialized,
                    _iso(current_time),
                ),
            )
            conn.execute(
                "INSERT INTO operational_credential_state_events (state_hash) VALUES (?)",
                (digest,),
            )
            if owns_connection:
                conn.commit()
        except sqlite3.IntegrityError as exc:
            raise OperationalCredentialConflict("Operational Credential state conflict") from exc
    return digest, True


def validate_live_operational_state(
    state: Mapping[str, Any],
    *,
    now: datetime | None = None,
) -> None:
    """Require a current certificate and the exact locally known chain head."""
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    node_id = state.get("node_id") if isinstance(state, Mapping) else None
    if not isinstance(node_id, str):
        raise HTTPException(status_code=400, detail="invalid credential state NodeID")
    head = operational_credential_head(node_id)
    if head is None:
        raise HTTPException(status_code=403, detail="credential high-watermark is unknown")
    try:
        digest = operational_credential_state_hash(state)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid credential state") from exc
    if digest != head["state_hash"]:
        raise HTTPException(status_code=409, detail="credential state is not the current high-watermark")
    validation = validate_operational_credential_state(
        state,
        now=current_time,
        expected_node_id=node_id,
        expected_epoch=head["state"]["credential_epoch"],
        expected_previous_hash=head["state"]["previous_state_hash"],
        require_current_certificate=True,
    )
    if not validation.valid:
        raise HTTPException(status_code=403, detail=validation.reason or "invalid live credential state")
    from app.operational_credential_revocation_store import (
        require_operational_credential_not_revoked,
    )

    require_operational_credential_not_revoked(
        state["operational_certificate"], at_time=current_time
    )


def admit_live_operational_credential(
    operational_certificate: Mapping[str, Any],
    credential_state: Mapping[str, Any] | None,
    *,
    mode: str,
    now: datetime | None = None,
) -> bool:
    """Admit a live credential without applying its policy to historical events.

    Returns True when a supplied state was enforced, False for an allowed
    report/off compatibility path.
    """
    if mode not in {"off", "report", "enforce"}:
        raise ValueError("invalid Operational Credential state mode")
    if mode == "off":
        return False
    if credential_state is None:
        if mode == "enforce":
            raise HTTPException(status_code=403, detail="Operational Credential state is required")
        return False
    if not isinstance(credential_state, Mapping):
        raise HTTPException(status_code=400, detail="credential state must be an object")
    state_certificate = credential_state.get("operational_certificate")
    try:
        if canonical_json(dict(state_certificate)) != canonical_json(
            dict(operational_certificate)
        ):
            raise HTTPException(
                status_code=403,
                detail="live certificate does not match credential state",
            )
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid live credential state") from exc
    try:
        publish_operational_credential_state(
            credential_state,
            now=now,
            require_known_subject=True,
        )
    except OperationalCredentialConflict as exc:
        # Import locally so the persistence layer remains usable by isolated
        # tests and migration tooling without initializing the network guard.
        from app.network_guard import get_network_view_guard

        get_network_view_guard().force_freeze(
            "conflicting root-signed Operational Credential states detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    except OperationalCredentialRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    validate_live_operational_state(credential_state, now=now)
    return True
