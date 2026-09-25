"""Cryptographically provable Security Reputation proposals."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from typing import Any

from app.config import TRUST_LEDGER_DB_PATH
from app.db import get_conn
from shared.security.canonical import canonical_json
from shared.security.trust_ledger import TrustLedgerStore


def _common_signers(first: dict, second: dict) -> tuple[str, ...]:
    first_ids = {
        item.get("validator_id")
        for item in first.get("signatures", [])
        if isinstance(item, dict)
    }
    second_ids = {
        item.get("validator_id")
        for item in second.get("signatures", [])
        if isinstance(item, dict)
    }
    return tuple(sorted((first_ids & second_ids) - {None}))


def _credential_revocation_equivocations(limit: int) -> list[dict[str, Any]]:
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT c.node_id, c.revocation_epoch, c.existing_hash,
                      c.conflicting_hash, c.conflicting_json,
                      r.revocation_json AS existing_json
               FROM operational_credential_revocation_conflicts AS c
               JOIN operational_credential_revocations AS r
                 ON r.revocation_hash = c.existing_hash
               ORDER BY c.id DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return [
        {
            "violation": "operational_credential_revocation_equivocation",
            "subject_node_id": row["node_id"],
            "epoch": row["revocation_epoch"],
            "first_hash": row["existing_hash"],
            "second_hash": row["conflicting_hash"],
            "validators": _common_signers(
                json.loads(row["existing_json"]),
                json.loads(row["conflicting_json"]),
            ),
            "existing_object": json.loads(row["existing_json"]),
            "conflicting_object": json.loads(row["conflicting_json"]),
            "detected_at": row["detected_at"],
        }
        for row in rows
    ]


def security_reputation_candidates(*, limit: int = 1000) -> list[dict[str, Any]]:
    """Attribute common signatures on supported conflicting valid objects."""
    evidence = TrustLedgerStore(TRUST_LEDGER_DB_PATH).equivocation_evidence(
        limit=limit
    )
    by_validator: dict[str, list[dict[str, Any]]] = {}
    for item in evidence:
        for validator_id in item["equivocating_validators"]:
            by_validator.setdefault(validator_id, []).append(item)
    for item in _credential_revocation_equivocations(limit):
        for validator_id in item["validators"]:
            by_validator.setdefault(validator_id, []).append(item)

    generated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    candidates = []
    for validator_id in sorted(by_validator):
        items = by_validator[validator_id]
        unique_proofs = {
            (
                item.get("violation", "trust_record_equivocation"),
                item["subject_node_id"],
                item["epoch"],
                item.get("existing_record_hash", item.get("first_hash")),
                item.get("conflicting_record_hash", item.get("second_hash")),
            )
            for item in items
        }
        proof_items = [
            {
                "violation": violation,
                "subject_node_id": subject,
                "epoch": epoch,
                "first_hash": first_hash,
                "second_hash": second_hash,
            }
            for violation, subject, epoch, first_hash, second_hash in sorted(unique_proofs)
        ]
        proposal = {
            "protocol_version": "ouo-security-reputation-proposal/1",
            "subject_node_id": validator_id,
            "violation": "validator_equivocation",
            "proofs": proof_items,
            "recommended_action": "suspension",
        }
        evidence_decided_at = max(
            item.get("detected_at", generated_at) for item in items
        )
        candidates.append(
            {
                **proposal,
                "proof_count": len(proof_items),
                "evidence_commitment": hashlib.sha256(
                    canonical_json(proposal).encode("utf-8")
                ).hexdigest(),
                "generated_at": generated_at,
                "evidence_decided_at": evidence_decided_at,
                "decision": "eligible_for_quorum_security_review",
            }
        )
    return candidates


def security_evidence(*, limit: int = 100) -> list[dict[str, Any]]:
    """Return complete signed object pairs for independent validator review."""
    result = []
    for item in TrustLedgerStore(TRUST_LEDGER_DB_PATH).equivocation_evidence(
        limit=limit
    ):
        result.append(
            {
                "violation": "trust_record_equivocation",
                "subject_node_id": item["subject_node_id"],
                "epoch": item["epoch"],
                "first_hash": item["existing_record_hash"],
                "second_hash": item["conflicting_record_hash"],
                "first_object": item["existing_record"],
                "second_object": item["conflicting_record"],
                "equivocating_validators": item["equivocating_validators"],
            }
        )
    for item in _credential_revocation_equivocations(limit):
        result.append(
            {
                "violation": item["violation"],
                "subject_node_id": item["subject_node_id"],
                "epoch": item["epoch"],
                "first_hash": item["first_hash"],
                "second_hash": item["second_hash"],
                "first_object": item["existing_object"],
                "second_object": item["conflicting_object"],
                "equivocating_validators": list(item["validators"]),
            }
        )
    return sorted(
        result,
        key=lambda item: (
            item["violation"],
            item["subject_node_id"],
            item["epoch"],
            item["first_hash"],
            item["second_hash"],
        ),
    )[:limit]
