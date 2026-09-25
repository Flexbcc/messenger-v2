"""Strict partial-signature collector for evidence-bound TrustRecord proposals."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from app.config import TRUST_LEDGER_DB_PATH
from app.network_guard import require_governance_available
from app.trust_record_proposals import trust_record_matches_local_proposal
from app.trust_record_service import _authority_for_record, ingest_trust_record
from shared.security.keys import verify_message
from shared.security.trust_ledger import (
    TrustLedgerStore,
    trust_record_hash,
    trust_record_signing_payload,
)


def submit_trust_record_vote(
    *, proposal: Mapping[str, Any], validator_id: str, signature: str
) -> dict[str, Any]:
    require_governance_available()
    if not isinstance(proposal, Mapping):
        raise HTTPException(status_code=400, detail="proposal must be an object")
    unsigned = dict(proposal)
    if unsigned.get("signatures") != []:
        raise HTTPException(status_code=400, detail="validator must vote on unsigned proposal")
    if not trust_record_matches_local_proposal(unsigned):
        raise HTTPException(status_code=409, detail="proposal is unknown, stale or differs from local evidence")
    ledger_store = TrustLedgerStore(TRUST_LEDGER_DB_PATH)
    published = next(
        (
            record for record in ledger_store.records(unsigned["subject_node_id"])
            if record.get("record_id") == unsigned.get("record_id")
        ),
        None,
    )
    if published is not None:
        return {
            "record_id": unsigned["record_id"],
            "validator_id": validator_id,
            "votes": len(published["signatures"]),
            "threshold": published["threshold"],
            "quorum_reached": True,
            "accepted": False,
            "record_commitment": trust_record_hash(published),
        }
    head = ledger_store.latest_record(unsigned["subject_node_id"])
    if head is not None and head["epoch"] >= unsigned["epoch"]:
        raise HTTPException(status_code=409, detail="proposal is stale")
    authority = _authority_for_record(unsigned)
    if validator_id not in unsigned.get("committee", []) or validator_id not in authority.committee:
        raise HTTPException(status_code=403, detail="validator is outside assigned committee")
    credential = authority.validators.get(validator_id)
    if credential is None or credential.revoked:
        raise HTTPException(status_code=403, detail="validator credential is unavailable or revoked")
    try:
        decided_raw = unsigned["decided_at"]
        decided_at = datetime.fromisoformat(
            decided_raw[:-1] + "+00:00" if decided_raw.endswith("Z") else decided_raw
        ).astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        raise HTTPException(status_code=400, detail="invalid proposal decision time")
    if credential.valid_until.astimezone(timezone.utc) < decided_at:
        raise HTTPException(status_code=403, detail="validator credential expired before decision")
    if not isinstance(signature, str) or len(signature) != 88 or not verify_message(
        credential.public_key, trust_record_signing_payload(unsigned), signature
    ):
        raise HTTPException(status_code=400, detail="invalid validator signature")

    now_text = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        existing = conn.execute(
            "SELECT signature FROM trust_record_votes WHERE record_id = ? AND validator_id = ?",
            (unsigned["record_id"], validator_id),
        ).fetchone()
        if existing is not None and existing["signature"] != signature:
            raise HTTPException(status_code=409, detail="conflicting validator vote")
        conn.execute(
            """INSERT OR IGNORE INTO trust_record_votes
               (record_id, validator_id, signature, received_at) VALUES (?, ?, ?, ?)""",
            (unsigned["record_id"], validator_id, signature, now_text),
        )
        rows = conn.execute(
            """SELECT validator_id, signature FROM trust_record_votes
               WHERE record_id = ? ORDER BY validator_id""",
            (unsigned["record_id"],),
        ).fetchall()
        conn.commit()
    signatures = [dict(row) for row in rows]
    threshold = unsigned["threshold"]
    result: dict[str, Any] = {
        "record_id": unsigned["record_id"],
        "validator_id": validator_id,
        "votes": len(signatures),
        "threshold": threshold,
        "quorum_reached": len(signatures) >= threshold,
        "accepted": existing is None,
    }
    if len(signatures) >= threshold:
        quorum_record = dict(unsigned)
        quorum_record["signatures"] = signatures
        result["ledger"] = ingest_trust_record(quorum_record)
        result["record_commitment"] = trust_record_hash(quorum_record)
    return result
