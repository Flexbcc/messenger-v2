"""Deterministic reliability view over verified external observations."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import os

from app.db import get_conn
from shared.security.canonical import canonical_json
from shared.security.trust_evidence import CHALLENGE_TYPES, LATENCY_BUCKETS, RESULTS


MIN_PROMOTION_OBSERVATIONS = max(
    1, int(os.environ.get("TRUST_PROMOTION_MIN_OBSERVATIONS", "20"))
)
MIN_PROMOTION_OBSERVERS = max(
    2, int(os.environ.get("TRUST_PROMOTION_MIN_OBSERVERS", "3"))
)
MIN_PROMOTION_TYPES = max(
    1, int(os.environ.get("TRUST_PROMOTION_MIN_CHALLENGE_TYPES", "2"))
)
MIN_PROMOTION_SUCCESS_BPS = max(
    0, min(10_000, int(os.environ.get("TRUST_PROMOTION_MIN_SUCCESS_BPS", "9000")))
)


def reliability_snapshot(
    subject_node_id: str,
    *,
    now: datetime | None = None,
) -> dict:
    """Aggregate bounded evidence without making a promotion decision.

    At most the latest observation for `(observer, challenge_type, epoch)` has
    weight. Current non-trusted observers remain auditable in raw storage but do
    not contribute to this derived reliability view.
    """
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    current_iso = current_time.isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        subject = conn.execute(
            """SELECT node_id, trust_status, trust_level, registered_at
               FROM node_capabilities WHERE identity_node_id = ?""",
            (subject_node_id,),
        ).fetchone()
        rows = conn.execute(
            """
            SELECT o.*, n.trust_status AS observer_trust_status,
                   n.node_identity_status AS observer_identity_status
            FROM trust_observations AS o
            LEFT JOIN node_capabilities AS n
              ON n.identity_node_id = o.observer_node_id
            WHERE o.subject_node_id = ? AND o.expires_at >= ?
            ORDER BY o.observed_at DESC, o.observation_id DESC
            """,
            (subject_node_id, current_iso),
        ).fetchall()
        assignment_rows = conn.execute(
            """SELECT a.expires_at, o.state
               FROM challenge_assignments AS a
               JOIN challenge_assignment_observers AS o
                 ON o.assignment_id = a.assignment_id
               WHERE a.subject_node_id = ?""",
            (subject_node_id,),
        ).fetchall()

    eligible = [
        row
        for row in rows
        if row["observer_trust_status"] == "trusted"
        and row["observer_identity_status"] == "valid"
    ]
    effective = []
    seen = set()
    for row in eligible:
        weight_key = (row["observer_node_id"], row["challenge_type"], row["epoch"])
        if weight_key in seen:
            continue
        seen.add(weight_key)
        effective.append(row)

    result_counts = {result: 0 for result in sorted(RESULTS)}
    latency_counts = {bucket: 0 for bucket in sorted(LATENCY_BUCKETS)}
    type_counts = {challenge_type: 0 for challenge_type in sorted(CHALLENGE_TYPES)}
    for row in effective:
        result_counts[row["result"]] += 1
        latency_counts[row["latency_bucket"]] += 1
        type_counts[row["challenge_type"]] += 1
    effective_count = len(effective)
    success_rate_bps = (
        round(result_counts["success"] * 10_000 / effective_count)
        if effective_count
        else None
    )
    epochs = [row["epoch"] for row in effective]
    evidence_decided_at = (
        max(row["observed_at"] for row in effective)
        if effective
        else current_iso
    )
    current_level = (subject["trust_level"] or 0) if subject is not None else None
    target_level = (
        current_level + 1
        if isinstance(current_level, int) and current_level < 5
        else None
    )
    covered_types = sum(1 for count in type_counts.values() if count > 0)
    assigned_slots = len(assignment_rows)
    completed_slots = sum(row["state"] == "completed" for row in assignment_rows)
    expired_incomplete_slots = sum(
        row["state"] != "completed" and row["expires_at"] < current_iso
        for row in assignment_rows
    )
    assignment_completion_bps = (
        round(completed_slots * 10_000 / assigned_slots)
        if assigned_slots
        else None
    )
    missing = []
    if subject is None:
        missing.append("unknown_subject")
    elif subject["trust_status"] != "trusted":
        missing.append("subject_not_trusted")
    if effective_count < MIN_PROMOTION_OBSERVATIONS:
        missing.append(f"effective_observations<{MIN_PROMOTION_OBSERVATIONS}")
    observer_count = len({row["observer_node_id"] for row in effective})
    if observer_count < MIN_PROMOTION_OBSERVERS:
        missing.append(f"independent_observers<{MIN_PROMOTION_OBSERVERS}")
    if covered_types < MIN_PROMOTION_TYPES:
        missing.append(f"challenge_types<{MIN_PROMOTION_TYPES}")
    if success_rate_bps is None or success_rate_bps < MIN_PROMOTION_SUCCESS_BPS:
        missing.append(f"success_rate_bps<{MIN_PROMOTION_SUCCESS_BPS}")
    if result_counts["invalid"]:
        missing.append("protocol_invalid_result_present")
    if target_level is None:
        missing.append("maximum_level_reached")
    decision = "eligible_for_quorum_review" if not missing else "not_eligible"
    evidence = {
        "protocol_version": "ouo-trust-eligibility/1",
        "policy": {
            "minimum_observations": MIN_PROMOTION_OBSERVATIONS,
            "minimum_observers": MIN_PROMOTION_OBSERVERS,
            "minimum_challenge_types": MIN_PROMOTION_TYPES,
            "minimum_success_bps": MIN_PROMOTION_SUCCESS_BPS,
            "invalid_result_allowed": False,
        },
        "subject_node_id": subject_node_id,
        "current_level": current_level,
        "proposed_level": target_level,
        "effective_observations": effective_count,
        "observer_count": observer_count,
        "challenge_type_count": covered_types,
        "result_counts": result_counts,
        "minimum_epoch": min(epochs) if epochs else None,
        "maximum_epoch": max(epochs) if epochs else None,
        "success_rate_bps": success_rate_bps,
        "assigned_observer_slots": assigned_slots,
        "completed_observer_slots": completed_slots,
        "expired_incomplete_observer_slots": expired_incomplete_slots,
        "assignment_completion_bps": assignment_completion_bps,
        "decision": decision,
        "missing": missing,
    }
    return {
        "subject_node_id": subject_node_id,
        "subject_known": subject is not None,
        "generated_at": current_iso,
        "raw_observations": len(rows),
        "trusted_observations": len(eligible),
        "effective_observations": effective_count,
        "observer_count": observer_count,
        "observer_diversity": "node_id_only_unproven",
        "result_counts": result_counts,
        "latency_buckets": latency_counts,
        "challenge_types": type_counts,
        "minimum_epoch": min(epochs) if epochs else None,
        "maximum_epoch": max(epochs) if epochs else None,
        "success_rate_bps": success_rate_bps,
        "assigned_observer_slots": assigned_slots,
        "completed_observer_slots": completed_slots,
        "expired_incomplete_observer_slots": expired_incomplete_slots,
        "assignment_completion_bps": assignment_completion_bps,
        "current_level": current_level,
        "proposed_level": target_level,
        "eligibility_missing": missing,
        "evidence_commitment": hashlib.sha256(
            canonical_json(evidence).encode("utf-8")
        ).hexdigest(),
        "eligibility_policy": evidence["policy"],
        "evidence_decided_at": evidence_decided_at,
        "promotion_decision": decision,
    }
