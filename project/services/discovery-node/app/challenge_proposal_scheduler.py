"""Deterministic unsigned synthetic-challenge proposal scheduler."""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.config import (
    CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS,
    CHALLENGE_PROPOSAL_SCHEDULER_MODE,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.db import get_conn
from app.randomness_checkpoint_store import latest_randomness_checkpoint
from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.challenge_assignment import challenge_assignment_hash
from shared.security.challenge_scheduler import build_challenge_assignment_proposal


logger = logging.getLogger(__name__)
CAPABILITY_CHALLENGES = {
    "relay": "relay_delivery",
    "storage": "storage_store_get",
    "discovery": "discovery_lookup",
}


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("checkpoint time must include timezone")
    return parsed.astimezone(timezone.utc)


def _subject_challenges(row) -> tuple[str, ...]:
    try:
        capabilities = json.loads(row["certified_capabilities"] or "[]")
    except (TypeError, ValueError):
        capabilities = []
    challenge_types = {"availability"}
    if isinstance(capabilities, list):
        challenge_types.update(
            CAPABILITY_CHALLENGES[capability]
            for capability in capabilities
            if capability in CAPABILITY_CHALLENGES
        )
    return tuple(sorted(challenge_types))


def _previous_hash(
    conn,
    subject_node_id: str,
    challenge_type: str,
    *,
    before_epoch: int,
) -> str | None:
    row = conn.execute(
        """SELECT assignment_json FROM challenge_assignments
           WHERE subject_node_id = ? AND challenge_type = ? AND epoch < ?
           ORDER BY epoch DESC LIMIT 1""",
        (subject_node_id, challenge_type, before_epoch),
    ).fetchone()
    return (
        challenge_assignment_hash(json.loads(row["assignment_json"]))
        if row is not None
        else None
    )


def generate_challenge_proposals(*, now: datetime | None = None) -> dict[str, int]:
    """Persist repeat-safe unsigned proposals for the latest validated epoch."""
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    stored = latest_randomness_checkpoint()
    if stored is None:
        return {"created": 0, "existing": 0, "skipped": 0}
    checkpoint = stored["checkpoint"]
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    authority = load_authority_state_at_epoch(
        TRUST_AUTHORITY_STATE_PATH,
        checkpoint["authority_epoch"],
        bootstrap_state=bootstrap,
    )
    if authority is None:
        raise ValueError("challenge proposal authority state is unavailable")
    not_before = _parse_time(checkpoint["issued_at"])
    expires_at = min(
        not_before + timedelta(hours=1),
        _parse_time(checkpoint["valid_until"]),
    )
    if current > expires_at:
        return {"created": 0, "existing": 0, "skipped": 1}

    created = 0
    existing = 0
    skipped = 0
    created_at = current.isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        subjects = conn.execute(
            """SELECT identity_node_id, certified_capabilities
               FROM node_capabilities
               WHERE identity_node_id IS NOT NULL
                 AND node_identity_status = 'valid'
                 AND trust_status = 'trusted'
               ORDER BY identity_node_id"""
        ).fetchall()
        for subject in subjects:
            for challenge_type in _subject_challenges(subject):
                if challenge_type == "relay_delivery" and checkpoint["observer_count"] < 2:
                    skipped += 1
                    continue
                try:
                    proposal = build_challenge_assignment_proposal(
                        checkpoint=checkpoint,
                        authority_state=authority,
                        subject_node_id=subject["identity_node_id"],
                        challenge_type=challenge_type,
                        not_before=not_before,
                        expires_at=expires_at,
                        previous_hash=_previous_hash(
                            conn,
                            subject["identity_node_id"],
                            challenge_type,
                            before_epoch=checkpoint["challenge_epoch"],
                        ),
                    )
                except ValueError:
                    skipped += 1
                    continue
                serialized = canonical_json(proposal)
                row = conn.execute(
                    """SELECT proposal_json FROM challenge_assignment_proposals
                       WHERE assignment_id = ?""",
                    (proposal["assignment_id"],),
                ).fetchone()
                if row is not None:
                    if row["proposal_json"] != serialized:
                        raise RuntimeError("deterministic challenge proposal conflict")
                    existing += 1
                    continue
                conn.execute(
                    """INSERT INTO challenge_assignment_proposals (
                           assignment_id, subject_node_id, challenge_type, epoch,
                           proposal_json, created_at
                       ) VALUES (?, ?, ?, ?, ?, ?)""",
                    (
                        proposal["assignment_id"],
                        proposal["subject_node_id"],
                        proposal["challenge_type"],
                        proposal["epoch"],
                        serialized,
                        created_at,
                    ),
                )
                created += 1
        conn.commit()
    return {"created": created, "existing": existing, "skipped": skipped}


def list_challenge_proposals(*, after_epoch: int = -1, limit: int = 100) -> list[dict]:
    if after_epoch < -1 or not 1 <= limit <= 1000:
        raise ValueError("invalid proposal pagination")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT p.proposal_json, a.assignment_id AS published_id
               FROM challenge_assignment_proposals AS p
               LEFT JOIN challenge_assignments AS a
                 ON a.assignment_id = p.assignment_id
               WHERE p.epoch > ? ORDER BY p.epoch, p.subject_node_id,
                   p.challenge_type LIMIT ?""",
            (after_epoch, limit),
        ).fetchall()
    now = datetime.now(timezone.utc)
    result = []
    for row in rows:
        proposal = json.loads(row["proposal_json"])
        status = "published" if row["published_id"] is not None else "unsigned"
        if status == "unsigned" and _parse_time(proposal["expires_at"]) < now:
            status = "missed"
        result.append({"proposal": proposal, "status": status})
    return result


def challenge_proposal_status_counts() -> dict[str, int]:
    counts = {"unsigned": 0, "published": 0, "missed": 0}
    for item in list_challenge_proposals(after_epoch=-1, limit=1000):
        counts[item["status"]] += 1
    return counts


async def _proposal_loop() -> None:
    while True:
        try:
            from app.challenge_assignment_store import expire_assignment_observers

            expired = expire_assignment_observers()
            result = generate_challenge_proposals()
            if result["created"]:
                logger.info("created %d unsigned challenge proposals", result["created"])
            if expired:
                logger.info("expired %d unfinished challenge observer jobs", expired)
        except Exception as exc:
            logger.warning("challenge proposal scheduler failed: %s", exc)
        await asyncio.sleep(CHALLENGE_PROPOSAL_SCHEDULER_INTERVAL_SECONDS)


def start_challenge_proposal_scheduler() -> asyncio.Task | None:
    if CHALLENGE_PROPOSAL_SCHEDULER_MODE == "off":
        return None
    return asyncio.create_task(_proposal_loop())


def assignment_matches_local_proposal(assignment: dict[str, Any]) -> bool:
    """Compare the complete signing payload, excluding collected signatures."""
    with get_conn() as conn:
        row = conn.execute(
            """SELECT proposal_json FROM challenge_assignment_proposals
               WHERE assignment_id = ?""",
            (assignment.get("assignment_id"),),
        ).fetchone()
    if row is None:
        return False
    proposed = json.loads(row["proposal_json"])
    candidate = dict(assignment)
    candidate["signatures"] = []
    return canonical_json(candidate) == canonical_json(proposed)
