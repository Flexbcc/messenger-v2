"""Offline reliability signals for quorum-controlled Trust degradation.

In the target security model a Discovery observation is evidence, not an
authority decision. ``observe`` therefore records candidates without changing
the node level. Only a validated quorum TrustRecord may apply degradation.
``legacy`` preserves the old direct mutation path only when Trust Ledger is off.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

from app.config import TRUST_DEGRADATION_MODE
from app.db import get_conn
from app.trust import reachability_for
from shared.security.canonical import canonical_json


logger = logging.getLogger(__name__)
DEGRADE_L2_AFTER_DAYS = int(os.environ.get("TRUST_DEGRADE_L2_AFTER_DAYS", "7"))
DEGRADE_L1_AFTER_DAYS = int(os.environ.get("TRUST_DEGRADE_L1_AFTER_DAYS", "14"))
DEGRADATION_CHECK_INTERVAL_SECONDS = int(
    os.environ.get("TRUST_DEGRADATION_CHECK_INTERVAL_SECONDS", "3600")
)


def _aware(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _offline_since(last_heartbeat_iso: str, *, now: datetime | None = None) -> timedelta:
    last = _aware(datetime.fromisoformat(last_heartbeat_iso))
    current = _aware(now or datetime.now(timezone.utc))
    return current - last


def _proposal(trust_level: int, offline_duration: timedelta) -> tuple[int, str] | None:
    if trust_level == 2 and offline_duration >= timedelta(days=DEGRADE_L2_AFTER_DAYS):
        return (
            1,
            f"offline {offline_duration.days} days; L2→L1 threshold "
            f"{DEGRADE_L2_AFTER_DAYS} days",
        )
    if trust_level >= 1 and offline_duration >= timedelta(days=DEGRADE_L1_AFTER_DAYS):
        return (
            0,
            f"offline {offline_duration.days} days; L{trust_level}→L0 threshold "
            f"{DEGRADE_L1_AFTER_DAYS} days",
        )
    return None


def _candidate(
    row,
    *,
    proposed_level: int,
    offline_duration: timedelta,
    observed_at: datetime,
) -> dict[str, Any]:
    evidence = {
        "protocol_version": "ouo-trust-degradation-candidate/1",
        "subject_node_id": row["identity_node_id"],
        "previous_level": row["trust_level"],
        "proposed_level": proposed_level,
        "last_heartbeat": row["last_heartbeat"],
        "offline_seconds_bucket": int(offline_duration.total_seconds() // 3600) * 3600,
        "observed_at": observed_at.isoformat().replace("+00:00", "Z"),
    }
    return {
        **evidence,
        "legacy_node_id": row["node_id"],
        "offline_seconds": max(0, int(offline_duration.total_seconds())),
        "evidence_commitment": hashlib.sha256(
            canonical_json(evidence).encode("utf-8")
        ).hexdigest(),
    }


def _degrade_once(*, now: datetime | None = None) -> int:
    """Record candidates, or mutate only in explicitly isolated legacy mode."""
    if TRUST_DEGRADATION_MODE == "off":
        return 0
    current = _aware(now or datetime.now(timezone.utc))
    current_iso = current.isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT node_id, identity_node_id, last_heartbeat,
                      trust_level, trust_status
               FROM node_capabilities
               WHERE trust_status = 'trusted' AND trust_level >= 1"""
        ).fetchall()

    candidates = []
    legacy_changes = 0
    for row in rows:
        if reachability_for(row["last_heartbeat"]) != "offline":
            continue
        offline_duration = _offline_since(row["last_heartbeat"], now=current)
        proposal = _proposal(row["trust_level"] or 0, offline_duration)
        if proposal is None:
            continue
        new_level, reason = proposal
        if TRUST_DEGRADATION_MODE == "legacy":
            with get_conn() as conn:
                conn.execute(
                    """UPDATE node_capabilities
                       SET trust_level = ?, trust_level_updated_at = ?
                       WHERE node_id = ?""",
                    (new_level, current_iso, row["node_id"]),
                )
                conn.execute(
                    """INSERT INTO trust_level_history
                       (node_id, from_level, to_level, reason, actor, changed_at)
                       VALUES (?, ?, ?, ?, 'legacy-auto', ?)""",
                    (row["node_id"], row["trust_level"], new_level, reason, current_iso),
                )
                conn.commit()
            legacy_changes += 1
            logger.warning(
                "legacy trust degradation applied: %s L%d→L%d",
                row["node_id"],
                row["trust_level"],
                new_level,
            )
            continue
        if not row["identity_node_id"]:
            logger.warning(
                "offline node %s has no verified NodeID; no Trust candidate emitted",
                row["node_id"],
            )
            continue
        candidates.append(
            _candidate(
                row,
                proposed_level=new_level,
                offline_duration=offline_duration,
                observed_at=current,
            )
        )

    if TRUST_DEGRADATION_MODE == "observe":
        with get_conn() as conn:
            conn.execute("DELETE FROM trust_degradation_candidates")
            conn.executemany(
                """INSERT INTO trust_degradation_candidates (
                       subject_node_id, legacy_node_id, previous_level,
                       proposed_level, last_heartbeat, offline_seconds,
                       evidence_commitment, observed_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    (
                        item["subject_node_id"],
                        item["legacy_node_id"],
                        item["previous_level"],
                        item["proposed_level"],
                        item["last_heartbeat"],
                        item["offline_seconds"],
                        item["evidence_commitment"],
                        item["observed_at"],
                    )
                    for item in candidates
                ],
            )
            conn.commit()
    return len(candidates) if TRUST_DEGRADATION_MODE == "observe" else legacy_changes


def list_degradation_candidates(*, limit: int = 100) -> list[dict[str, Any]]:
    if not 1 <= limit <= 1000:
        raise ValueError("limit must be between 1 and 1000")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT subject_node_id, previous_level, proposed_level,
                      last_heartbeat, offline_seconds, evidence_commitment, observed_at
               FROM trust_degradation_candidates
               ORDER BY observed_at DESC, subject_node_id LIMIT ?""",
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


async def _degradation_loop() -> None:
    logger.info(
        "Trust degradation worker mode=%s, check interval=%ds",
        TRUST_DEGRADATION_MODE,
        DEGRADATION_CHECK_INTERVAL_SECONDS,
    )
    while True:
        await asyncio.sleep(DEGRADATION_CHECK_INTERVAL_SECONDS)
        try:
            count = _degrade_once()
            if count:
                logger.info("Trust degradation candidates/changes: %d", count)
        except Exception as exc:
            logger.error("Trust degradation iteration failed: %s", exc)


def start_trust_degradation() -> asyncio.Task | None:
    if TRUST_DEGRADATION_MODE == "off":
        return None
    return asyncio.create_task(_degradation_loop())
