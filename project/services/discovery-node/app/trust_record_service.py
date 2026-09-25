"""Validation, persistence and legacy-state application for TrustRecords."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.config import TRUST_AUTHORITY_STATE_PATH, TRUST_LEDGER_DB_PATH, TRUST_LEDGER_MODE
from app.db import get_conn
from app.network_guard import get_network_view_guard, require_governance_available
from app.trust import now_iso
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.trust_ledger import (
    TrustLedgerConflict,
    TrustLedgerStore,
    trust_record_hash,
    validate_trust_record,
)


def _authority_for_record(record: Mapping[str, Any]):
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    try:
        authority = load_authority_state_at_epoch(
            TRUST_AUTHORITY_STATE_PATH,
            record.get("authority_epoch"),
            bootstrap_state=bootstrap,
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid Trust authority state: {exc}")
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="authority state for TrustRecord epoch is unavailable",
        )
    return authority


def _apply_record_to_registered_node(record: Mapping[str, Any]) -> bool:
    """Apply one already-validated transition to the legacy Discovery projection."""
    with get_conn() as conn:
        node = conn.execute(
            "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
            (record["subject_node_id"],),
        ).fetchone()
        if node is None:
            return False
        current_level = node["trust_level"] if node["trust_level"] is not None else 0
        current_status = node["trust_status"] or "unknown"
        already_applied = (
            record["action"] in {"promotion", "degradation"}
            and current_level == record["new_level"]
        ) or (
            record["action"] == "suspension" and current_status == "suspended"
        ) or (
            record["action"] == "reinstatement" and current_status == "trusted"
        ) or (
            record["action"] == "revocation"
            and current_level == 0
            and current_status == "compromised"
        )
        if already_applied:
            return False
        if current_level != record["previous_level"]:
            raise HTTPException(
                status_code=409,
                detail="TrustRecord previous_level does not match Discovery state",
            )
        if record["action"] in {"promotion", "degradation"} and current_status != "trusted":
            raise HTTPException(
                status_code=409,
                detail="level transition requires a trusted node",
            )

        changed_at = now_iso()
        legacy_node_id = node["node_id"]
        if record["action"] in {"promotion", "degradation"}:
            conn.execute(
                "UPDATE node_capabilities SET trust_level = ?, trust_level_updated_at = ? WHERE node_id = ?",
                (record["new_level"], changed_at, legacy_node_id),
            )
        elif record["action"] == "suspension":
            conn.execute(
                """UPDATE node_capabilities
                   SET trust_status = 'suspended', suspended_at = ?, suspension_reason = ?
                   WHERE node_id = ?""",
                (changed_at, "quorum TrustRecord", legacy_node_id),
            )
        elif record["action"] == "reinstatement":
            if current_status != "suspended":
                raise HTTPException(
                    status_code=409,
                    detail="reinstatement requires a suspended node",
                )
            conn.execute(
                """UPDATE node_capabilities
                   SET trust_status = 'trusted', suspended_at = NULL,
                       suspension_reason = NULL
                   WHERE node_id = ?""",
                (legacy_node_id,),
            )
        elif record["action"] == "revocation":
            conn.execute(
                """UPDATE node_capabilities SET
                       trust_level = 0, trust_status = 'compromised',
                       node_token_hash = NULL, token_issued_at = NULL,
                       token_claimed_at = NULL, trust_level_updated_at = ?
                   WHERE node_id = ?""",
                (changed_at, legacy_node_id),
            )
        conn.execute(
            """INSERT INTO trust_level_history
               (node_id, from_level, to_level, reason, actor, changed_at)
               VALUES (?, ?, ?, ?, 'validator-quorum', ?)""",
            (
                legacy_node_id,
                record["previous_level"],
                record["new_level"],
                f"{record['action']} TrustRecord {record['record_id']}",
                changed_at,
            ),
        )
        conn.commit()
    return True


def reconcile_registered_subject(subject_node_id: str) -> int:
    """Apply a validated chain that arrived before the node registered locally."""
    if TRUST_LEDGER_MODE != "enforce":
        return 0
    applied = 0
    for record in TrustLedgerStore(TRUST_LEDGER_DB_PATH).records(subject_node_id):
        if _apply_record_to_registered_node(record):
            applied += 1
    return applied


def ingest_trust_record(
    record: Mapping[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Validate and append a quorum decision received locally or by gossip."""
    if TRUST_LEDGER_MODE == "off":
        raise HTTPException(status_code=503, detail="Trust Ledger endpoint is disabled")
    require_governance_available()
    authority = _authority_for_record(record)
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    validation = validate_trust_record(
        record,
        now=current_time,
        expected_committee=authority.committee,
        expected_threshold=authority.threshold,
        validator_credentials=authority.validators,
        minimum_epoch=0,
        expected_authority_epoch=authority.epoch,
    )
    if not validation.valid:
        raise HTTPException(status_code=400, detail=validation.reason)

    digest = trust_record_hash(record)
    store = TrustLedgerStore(TRUST_LEDGER_DB_PATH)
    already_known = store.contains_hash(digest)
    accepted = False
    if not already_known:
        try:
            accepted = store.append_validated(
                record,
                now=current_time,
                expected_committee=authority.committee,
                expected_threshold=authority.threshold,
                validator_credentials=authority.validators,
                minimum_epoch=0,
                expected_authority_epoch=authority.epoch,
            )
        except TrustLedgerConflict as exc:
            get_network_view_guard().force_freeze(
                "conflicting quorum TrustRecords detected"
            )
            raise HTTPException(status_code=409, detail=str(exc))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))

    applied = False
    if TRUST_LEDGER_MODE == "enforce" and (accepted or already_known):
        applied = _apply_record_to_registered_node(record)
    return {
        "record_hash": digest,
        "accepted": accepted,
        "applied": applied,
        "action": record["action"],
        "subject_node_id": record["subject_node_id"],
        "new_level": record["new_level"],
    }
