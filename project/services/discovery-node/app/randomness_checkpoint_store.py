"""Persistent quorum-validated challenge randomness checkpoint chain."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from shared.security.authority_checkpoint import authority_state_hash
from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.randomness_checkpoint import (
    randomness_checkpoint_hash,
    validate_randomness_checkpoint,
)


MAX_CHECKPOINT_BYTES = 512 * 1024


class RandomnessCheckpointConflict(RuntimeError):
    """Two different quorum checkpoints claim the same challenge epoch."""


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _latest_row(conn: sqlite3.Connection):
    return conn.execute(
        """SELECT challenge_epoch, authority_epoch, checkpoint_hash,
                  previous_hash, checkpoint_json, stored_at
           FROM randomness_checkpoints ORDER BY challenge_epoch DESC LIMIT 1"""
    ).fetchone()


def latest_randomness_checkpoint() -> dict[str, Any] | None:
    with get_conn() as conn:
        row = _latest_row(conn)
    if row is None:
        return None
    return {
        "checkpoint": json.loads(row["checkpoint_json"]),
        "checkpoint_hash": row["checkpoint_hash"],
        "stored_at": row["stored_at"],
    }


def randomness_checkpoint_by_hash(digest: str) -> dict[str, Any] | None:
    with get_conn() as conn:
        row = conn.execute(
            """SELECT checkpoint_json, checkpoint_hash, stored_at
               FROM randomness_checkpoints WHERE checkpoint_hash = ?""",
            (digest,),
        ).fetchone()
    if row is None:
        return None
    return {
        "checkpoint": json.loads(row["checkpoint_json"]),
        "checkpoint_hash": row["checkpoint_hash"],
        "stored_at": row["stored_at"],
    }


def list_randomness_checkpoints(
    *, after_epoch: int = -1, limit: int = 100
) -> list[dict[str, Any]]:
    if not isinstance(after_epoch, int) or isinstance(after_epoch, bool) or after_epoch < -1:
        raise ValueError("after_epoch must be at least -1")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT checkpoint_json, checkpoint_hash, stored_at
               FROM randomness_checkpoints WHERE challenge_epoch > ?
               ORDER BY challenge_epoch ASC LIMIT ?""",
            (after_epoch, limit),
        ).fetchall()
    return [
        {
            "checkpoint": json.loads(row["checkpoint_json"]),
            "checkpoint_hash": row["checkpoint_hash"],
            "stored_at": row["stored_at"],
        }
        for row in rows
    ]


def publish_randomness_checkpoint(
    checkpoint: Mapping[str, Any],
    *,
    authority_state: CapabilityAuthorityState,
    now: datetime | None = None,
) -> tuple[str, bool]:
    if not isinstance(checkpoint, Mapping):
        raise HTTPException(status_code=400, detail="checkpoint must be an object")
    try:
        serialized = canonical_json(dict(checkpoint))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="checkpoint must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_CHECKPOINT_BYTES:
        raise HTTPException(status_code=413, detail="randomness checkpoint exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    try:
        digest = randomness_checkpoint_hash(checkpoint)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid randomness checkpoint") from exc

    with get_conn() as conn:
        claimed_epoch = checkpoint.get("challenge_epoch")
        if isinstance(claimed_epoch, int) and not isinstance(claimed_epoch, bool):
            existing = conn.execute(
                """SELECT checkpoint_hash, checkpoint_json
                   FROM randomness_checkpoints WHERE challenge_epoch = ?""",
                (claimed_epoch,),
            ).fetchone()
            if existing is not None:
                if existing["checkpoint_hash"] == digest and existing["checkpoint_json"] == serialized:
                    return digest, False
                raise RandomnessCheckpointConflict(
                    "randomness checkpoint epoch equivocation"
                )
        latest = _latest_row(conn)
        if latest is None:
            expected_previous_hash = authority_state_hash(authority_state)
            checkpoint_epoch = checkpoint.get("challenge_epoch")
            minimum_epoch = (
                checkpoint_epoch - 1
                if isinstance(checkpoint_epoch, int)
                and not isinstance(checkpoint_epoch, bool)
                else -1
            )
        else:
            expected_previous_hash = latest["checkpoint_hash"]
            minimum_epoch = latest["challenge_epoch"]
        validation = validate_randomness_checkpoint(
            checkpoint,
            now=current_time,
            authority_state=authority_state,
            expected_previous_hash=expected_previous_hash,
            minimum_challenge_epoch=minimum_epoch,
        )
        if not validation.valid:
            raise HTTPException(
                status_code=400,
                detail=validation.reason or "invalid randomness checkpoint",
            )
        try:
            conn.execute(
                """INSERT INTO randomness_checkpoints (
                       challenge_epoch, authority_epoch, checkpoint_hash,
                       previous_hash, checkpoint_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?)""",
                (
                    checkpoint["challenge_epoch"],
                    checkpoint["authority_epoch"],
                    digest,
                    checkpoint["previous_hash"],
                    serialized,
                    _iso(current_time),
                ),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise RandomnessCheckpointConflict("randomness checkpoint conflict") from exc
    return digest, True
