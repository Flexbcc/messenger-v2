"""Deterministic unsigned TrustRecord proposals from verified evidence."""

from __future__ import annotations

import json
import asyncio
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from app.authority_checkpoint_store import load_effective_authority_state
from app.config import (
    TRUST_AUTHORITY_STATE_PATH,
    TRUST_LEDGER_DB_PATH,
    TRUST_PROPOSAL_INTERVAL_SECONDS,
    TRUST_PROPOSAL_MODE,
)
from app.db import get_conn
from app.security_reputation import security_reputation_candidates
from app.trust_degradation import list_degradation_candidates
from app.trust_reputation import reliability_snapshot
from shared.security.canonical import canonical_json
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.trust_ledger import (
    TrustLedgerStore,
    build_trust_record,
    trust_record_hash,
)


ACTION_PRIORITY = {"promotion": 1, "degradation": 2, "suspension": 3}
logger = logging.getLogger(__name__)


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("evidence time must include timezone")
    return parsed.astimezone(timezone.utc)


def _head(subject_node_id: str, fallback_level: int) -> tuple[int, int, str | None]:
    record = TrustLedgerStore(TRUST_LEDGER_DB_PATH).latest_record(subject_node_id)
    if record is None:
        return 0, fallback_level, None
    return record["epoch"] + 1, record["new_level"], trust_record_hash(record)


def _candidate_inputs() -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    with get_conn() as conn:
        nodes = conn.execute(
            """SELECT identity_node_id, trust_level FROM node_capabilities
               WHERE identity_node_id IS NOT NULL AND trust_status = 'trusted'
               ORDER BY identity_node_id"""
        ).fetchall()
    for node in nodes:
        snapshot = reliability_snapshot(node["identity_node_id"])
        if snapshot["promotion_decision"] == "eligible_for_quorum_review":
            candidates.append(
                {
                    "subject_node_id": node["identity_node_id"],
                    "action": "promotion",
                    "fallback_level": snapshot["current_level"],
                    "new_level": snapshot["proposed_level"],
                    "metrics_commitment": snapshot["evidence_commitment"],
                    "decided_at": snapshot["evidence_decided_at"],
                }
            )
    for item in list_degradation_candidates(limit=1000):
        candidates.append(
            {
                "subject_node_id": item["subject_node_id"],
                "action": "degradation",
                "fallback_level": item["previous_level"],
                "new_level": item["proposed_level"],
                "metrics_commitment": item["evidence_commitment"],
                "decided_at": item["observed_at"],
            }
        )
    for item in security_reputation_candidates(limit=1000):
        with get_conn() as conn:
            row = conn.execute(
                """SELECT trust_level FROM node_capabilities
                   WHERE identity_node_id = ?""",
                (item["subject_node_id"],),
            ).fetchone()
        if row is None:
            continue
        candidates.append(
            {
                "subject_node_id": item["subject_node_id"],
                "action": "suspension",
                "fallback_level": row["trust_level"] or 0,
                "new_level": row["trust_level"] or 0,
                "metrics_commitment": item["evidence_commitment"],
                "decided_at": item["evidence_decided_at"],
            }
        )
    selected: dict[str, dict[str, Any]] = {}
    for item in candidates:
        current = selected.get(item["subject_node_id"])
        if current is None or ACTION_PRIORITY[item["action"]] > ACTION_PRIORITY[current["action"]]:
            selected[item["subject_node_id"]] = item
    return [selected[key] for key in sorted(selected)]


def generate_trust_record_proposals() -> dict[str, int]:
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    authority = load_effective_authority_state(
        TRUST_AUTHORITY_STATE_PATH, bootstrap_state=bootstrap
    )
    if authority is None:
        raise ValueError("Trust authority state is unavailable")
    created = 0
    existing = 0
    now_text = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        for item in _candidate_inputs():
            epoch, previous_level, previous_hash = _head(
                item["subject_node_id"], item["fallback_level"]
            )
            if item["action"] != "suspension" and item["fallback_level"] != previous_level:
                # Evidence was calculated for another ledger level. Never
                # reinterpret it as a transition from the newer head.
                continue
            if item["action"] == "promotion":
                new_level = previous_level + 1
                if new_level > 5:
                    continue
            elif item["action"] == "degradation":
                new_level = min(item["new_level"], previous_level - 1)
                if new_level < 0:
                    continue
            else:
                new_level = previous_level
            decided_at = _parse_time(item["decided_at"])
            identity = "\x00".join(
                (
                    item["subject_node_id"],
                    item["action"],
                    str(epoch),
                    item["metrics_commitment"],
                    previous_hash or "",
                    str(authority.epoch),
                    decided_at.isoformat(),
                )
            )
            proposal = build_trust_record(
                subject_node_id=item["subject_node_id"],
                previous_level=previous_level,
                new_level=new_level,
                action=item["action"],
                epoch=epoch,
                authority_epoch=authority.epoch,
                metrics_commitment=item["metrics_commitment"],
                committee=authority.committee,
                threshold=authority.threshold,
                previous_hash=previous_hash,
                decided_at=decided_at,
                record_id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"ouo:trust:{identity}")),
            )
            serialized = canonical_json(proposal)
            row = conn.execute(
                "SELECT proposal_json FROM trust_record_proposals WHERE record_id = ?",
                (proposal["record_id"],),
            ).fetchone()
            if row is not None:
                if row["proposal_json"] != serialized:
                    raise RuntimeError("deterministic TrustRecord proposal conflict")
                existing += 1
                continue
            competing = conn.execute(
                """SELECT record_id, action FROM trust_record_proposals
                   WHERE subject_node_id = ? AND epoch = ?""",
                (proposal["subject_node_id"], proposal["epoch"]),
            ).fetchone()
            if competing is not None:
                if ACTION_PRIORITY[proposal["action"]] > ACTION_PRIORITY[competing["action"]]:
                    conn.execute(
                        """UPDATE trust_record_proposals SET
                               record_id = ?, action = ?, metrics_commitment = ?,
                               proposal_json = ?, created_at = ?
                           WHERE record_id = ?""",
                        (
                            proposal["record_id"], proposal["action"],
                            proposal["metrics_commitment"], serialized,
                            now_text, competing["record_id"],
                        ),
                    )
                    created += 1
                continue
            conn.execute(
                """INSERT INTO trust_record_proposals (
                       record_id, subject_node_id, epoch, action,
                       metrics_commitment, proposal_json, created_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    proposal["record_id"], proposal["subject_node_id"],
                    proposal["epoch"], proposal["action"],
                    proposal["metrics_commitment"], serialized, now_text,
                ),
            )
            created += 1
        conn.commit()
    return {"created": created, "existing": existing}


def list_trust_record_proposals(*, limit: int = 100) -> list[dict[str, Any]]:
    if not 1 <= limit <= 1000:
        raise ValueError("limit must be between 1 and 1000")
    store = TrustLedgerStore(TRUST_LEDGER_DB_PATH)
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT proposal_json FROM trust_record_proposals
               ORDER BY created_at DESC, subject_node_id LIMIT ?""",
            (limit,),
        ).fetchall()
    result = []
    for row in rows:
        proposal = json.loads(row["proposal_json"])
        published = any(
            record.get("record_id") == proposal["record_id"]
            for record in store.records(proposal["subject_node_id"])
        )
        status = "published" if published else "unsigned"
        head = store.latest_record(proposal["subject_node_id"])
        if status == "unsigned" and head is not None and head["epoch"] >= proposal["epoch"]:
            status = "stale"
        result.append({"proposal": proposal, "status": status})
    return result


def trust_record_matches_local_proposal(record: dict[str, Any]) -> bool:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT proposal_json FROM trust_record_proposals WHERE record_id = ?",
            (record.get("record_id"),),
        ).fetchone()
    if row is None:
        return False
    candidate = dict(record)
    candidate["signatures"] = []
    return canonical_json(candidate) == row["proposal_json"]


async def _proposal_loop() -> None:
    while True:
        try:
            result = generate_trust_record_proposals()
            if result["created"]:
                logger.info("created %d unsigned TrustRecord proposals", result["created"])
        except Exception as exc:
            logger.warning("TrustRecord proposal generation failed: %s", exc)
        await asyncio.sleep(TRUST_PROPOSAL_INTERVAL_SECONDS)


def start_trust_record_proposals() -> asyncio.Task | None:
    if TRUST_PROPOSAL_MODE == "off":
        return None
    return asyncio.create_task(_proposal_loop())
