"""Persistent quorum revocations for individual Operational Certificates."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.config import (
    OPERATIONAL_CREDENTIAL_REVOCATION_MODE,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.db import get_conn
from app.network_guard import get_network_view_guard, require_governance_available
from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.operational_credential_revocation import (
    MAX_REVOCATION_BYTES,
    operational_certificate_hash,
    operational_credential_revocation_genesis_hash,
    operational_credential_revocation_hash,
    validate_operational_credential_revocation,
)


MAX_REVOCATIONS_PER_NODE = 4096


class OperationalCredentialRevocationConflict(RuntimeError):
    """Two quorum objects occupy one per-node revocation epoch."""


class OperationalCredentialRevocationRollback(ValueError):
    """A lower revocation epoch was offered after a higher local head."""


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    ).astimezone(timezone.utc)


def _latest_row(conn: sqlite3.Connection, node_id: str):
    return conn.execute(
        """SELECT * FROM operational_credential_revocations
           WHERE node_id = ? ORDER BY revocation_epoch DESC LIMIT 1""",
        (node_id,),
    ).fetchone()


def _credential_state(conn: sqlite3.Connection, node_id: str, credential_epoch: int):
    return conn.execute(
        """SELECT state_json FROM operational_credential_states
           WHERE node_id = ? AND credential_epoch = ?""",
        (node_id, credential_epoch),
    ).fetchone()


def _authority_for_epoch(authority_epoch: int):
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    try:
        authority = load_authority_state_at_epoch(
            TRUST_AUTHORITY_STATE_PATH,
            authority_epoch,
            bootstrap_state=bootstrap,
        )
    except ValueError as exc:
        raise HTTPException(
            status_code=503, detail=f"invalid revocation authority state: {exc}"
        ) from exc
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="authority state for credential revocation is unavailable",
        )
    return authority


def operational_credential_revocation_latest_sequence() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(sequence), 0) FROM operational_credential_revocation_events"
        ).fetchone()
    return int(row[0])


def list_operational_credential_revocations(
    *, after_sequence: int = 0, limit: int = 100
) -> list[dict[str, Any]]:
    if not isinstance(after_sequence, int) or isinstance(after_sequence, bool) or after_sequence < 0:
        raise ValueError("after_sequence must be non-negative")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT e.sequence, r.revocation_hash, r.revocation_json, r.stored_at
               FROM operational_credential_revocation_events e
               JOIN operational_credential_revocations r
                 ON r.revocation_hash = e.revocation_hash
               WHERE e.sequence > ? ORDER BY e.sequence ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {
            "sequence": row["sequence"],
            "revocation": json.loads(row["revocation_json"]),
            "revocation_hash": row["revocation_hash"],
            "stored_at": row["stored_at"],
        }
        for row in rows
    ]


def publish_operational_credential_revocation(
    revocation: Mapping[str, Any], *, now: datetime | None = None
) -> tuple[str, bool]:
    if OPERATIONAL_CREDENTIAL_REVOCATION_MODE == "off":
        raise HTTPException(status_code=503, detail="credential revocation is disabled")
    require_governance_available()
    if not isinstance(revocation, Mapping):
        raise HTTPException(status_code=400, detail="revocation must be an object")
    try:
        serialized = canonical_json(dict(revocation))
        digest = operational_credential_revocation_hash(revocation)
        node_id = revocation["node_id"]
        epoch = revocation["revocation_epoch"]
        credential_epoch = revocation["credential_epoch"]
        authority_epoch = revocation["authority_epoch"]
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid credential revocation") from exc
    if len(serialized.encode("utf-8")) > MAX_REVOCATION_BYTES:
        raise HTTPException(status_code=413, detail="credential revocation exceeds size limit")
    supplied_time = now or datetime.now(timezone.utc)
    if supplied_time.tzinfo is None or supplied_time.utcoffset() is None:
        raise HTTPException(status_code=400, detail="validation time must be timezone-aware")
    current_time = supplied_time.astimezone(timezone.utc)
    if (
        not isinstance(node_id, str)
        or not isinstance(epoch, int)
        or isinstance(epoch, bool)
        or not isinstance(credential_epoch, int)
        or isinstance(credential_epoch, bool)
        or not isinstance(authority_epoch, int)
        or isinstance(authority_epoch, bool)
    ):
        raise HTTPException(status_code=400, detail="invalid credential revocation")
    authority = _authority_for_epoch(authority_epoch)

    with get_conn() as conn:
        existing = conn.execute(
            """SELECT revocation_hash, previous_hash, revocation_json
               FROM operational_credential_revocations
               WHERE node_id = ? AND revocation_epoch = ?""",
            (node_id, epoch),
        ).fetchone()
        if existing is not None:
            if existing["revocation_hash"] == digest and existing["revocation_json"] == serialized:
                return digest, False
            # A same-epoch object is not equivocation evidence until its own
            # certificate binding and quorum signatures are fully verified.
            expected_epoch = epoch
            expected_previous_hash = existing["previous_hash"]
            conflict_candidate = True
        else:
            conflict_candidate = False
            latest = _latest_row(conn, node_id)
            if latest is None:
                expected_epoch = 0
                try:
                    expected_previous_hash = operational_credential_revocation_genesis_hash(node_id)
                except ValueError as exc:
                    raise HTTPException(status_code=400, detail=str(exc)) from exc
            else:
                if epoch <= latest["revocation_epoch"]:
                    raise OperationalCredentialRevocationRollback(
                        "revocation is below the highest accepted epoch"
                    )
                expected_epoch = latest["revocation_epoch"] + 1
                expected_previous_hash = latest["revocation_hash"]
        if expected_epoch >= MAX_REVOCATIONS_PER_NODE:
            raise HTTPException(status_code=429, detail="revocation chain limit exceeded")
        state_row = _credential_state(conn, node_id, credential_epoch)
        if state_row is None:
            raise HTTPException(
                status_code=404,
                detail="referenced Operational Credential state is unavailable",
            )
        certificate = json.loads(state_row["state_json"])["operational_certificate"]
        validation = validate_operational_credential_revocation(
            revocation,
            operational_certificate=certificate,
            now=current_time,
            expected_revocation_epoch=expected_epoch,
            expected_previous_hash=expected_previous_hash,
            expected_committee=authority.committee,
            expected_threshold=authority.threshold,
            validator_credentials=authority.validators,
            expected_authority_epoch=authority.epoch,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason)
        if conflict_candidate:
            duplicate = conn.execute(
                """SELECT 1 FROM operational_credential_revocation_conflicts
                   WHERE node_id = ? AND revocation_epoch = ?
                     AND existing_hash = ? AND conflicting_hash = ?""",
                (node_id, epoch, existing["revocation_hash"], digest),
            ).fetchone()
            if duplicate is None:
                conn.execute(
                    """INSERT INTO operational_credential_revocation_conflicts
                   (node_id, revocation_epoch, existing_hash, conflicting_hash,
                    conflicting_json, detected_at) VALUES (?, ?, ?, ?, ?, ?)""",
                    (
                        node_id,
                        epoch,
                        existing["revocation_hash"],
                        digest,
                        serialized,
                        _iso(current_time),
                    ),
                )
                conn.commit()
            get_network_view_guard().force_freeze(
                "conflicting quorum Operational Credential revocations detected"
            )
            raise OperationalCredentialRevocationConflict(
                "credential revocation epoch equivocation"
            )
        try:
            conn.execute(
                """INSERT INTO operational_credential_revocations (
                       node_id, revocation_epoch, revocation_hash, previous_hash,
                       credential_epoch, certificate_serial, certificate_hash,
                       operational_public_key, authority_epoch, effective_at,
                       revocation_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    node_id,
                    epoch,
                    digest,
                    revocation["previous_hash"],
                    credential_epoch,
                    revocation["certificate_serial"],
                    revocation["certificate_hash"],
                    revocation["operational_public_key"],
                    authority_epoch,
                    revocation["effective_at"],
                    serialized,
                    _iso(current_time),
                ),
            )
            conn.execute(
                "INSERT INTO operational_credential_revocation_events (revocation_hash) VALUES (?)",
                (digest,),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise OperationalCredentialRevocationConflict(
                "Operational Credential revocation conflict"
            ) from exc
    return digest, True


def operational_credential_is_revoked(
    operational_certificate: Mapping[str, Any], *, at_time: datetime
) -> bool:
    if at_time.tzinfo is None or at_time.utcoffset() is None:
        raise ValueError("event time must be timezone-aware")
    try:
        node_id = operational_certificate["node_id"]
        serial = operational_certificate["serial"]
        digest = operational_certificate_hash(operational_certificate)
    except (KeyError, TypeError, ValueError):
        return False
    with get_conn() as conn:
        row = conn.execute(
            """SELECT effective_at FROM operational_credential_revocations
               WHERE node_id = ? AND certificate_serial = ? AND certificate_hash = ?""",
            (node_id, serial, digest),
        ).fetchone()
    return row is not None and _parse_time(row["effective_at"]) <= at_time.astimezone(timezone.utc)


def require_operational_credential_not_revoked(
    operational_certificate: Mapping[str, Any], *, at_time: datetime
) -> bool:
    """Reject only in enforce mode; return the observed revocation status."""
    revoked = operational_credential_is_revoked(
        operational_certificate, at_time=at_time
    )
    if revoked and OPERATIONAL_CREDENTIAL_REVOCATION_MODE == "enforce":
        raise HTTPException(
            status_code=403, detail="Operational Certificate has been revoked"
        )
    return not revoked
