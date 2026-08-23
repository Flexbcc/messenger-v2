"""Validate and persist quorum-issued synthetic challenge assignments."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from app.config import (
    CHALLENGE_PROPOSAL_SCHEDULER_MODE,
    OPERATIONAL_CREDENTIAL_STATE_MODE,
)
from app.operational_credential_store import admit_live_operational_credential
from app.operational_credential_revocation_store import (
    require_operational_credential_not_revoked,
)
from app.trust_admission import node_trust_denial_at
from app.security import verify_hash
from app.trust import enrollment_required
from app.config import RANDOMNESS_CHECKPOINT_MODE, TRUST_LEDGER_DB_PATH
from app.randomness_checkpoint_store import randomness_checkpoint_by_hash
from shared.security.canonical import canonical_json
from shared.security.challenge_scheduler import selected_observers_from_checkpoint
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.challenge_assignment import (
    challenge_assignment_hash,
    challenge_assignment_ack_hash,
    validate_assignment_ack,
    validate_challenge_assignment,
)
from shared.security.node_identity import validate_operational_certificate
from shared.security.observer_auth import validate_observer_request_proof


MAX_ASSIGNMENT_BYTES = 64 * 1024
MAX_ACK_BYTES = 16 * 1024
CLOCK_SKEW = timedelta(minutes=5)


class AssignmentConflict(RuntimeError):
    """A second quorum object claims the same subject/type/epoch."""


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    )
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _bearer_token(value: str | None) -> str | None:
    if not isinstance(value, str) or not value.startswith("Bearer "):
        return None
    token = value[7:].strip()
    return token or None


def _observer_row(conn: sqlite3.Connection, observer_node_id: str, authorization: str | None):
    observer = conn.execute(
        "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
        (observer_node_id,),
    ).fetchone()
    if observer is None or observer["node_identity_status"] != "valid":
        raise HTTPException(status_code=403, detail="unknown observer Node Identity")
    if (observer["trust_status"] or "unknown") != "trusted":
        raise HTTPException(status_code=403, detail="observer is not trusted")
    if observer["node_token_hash"] and enrollment_required():
        token = _bearer_token(authorization) or ""
        if not verify_hash(token, observer["node_token_hash"]):
            raise HTTPException(status_code=401, detail="invalid or missing observer node_token")
    return observer


def require_portable_observer_allowed(
    conn: sqlite3.Connection,
    observer_node_id: str,
    *,
    at_time: datetime | None = None,
    historical_event: bool = False,
    policy_time: datetime | None = None,
) -> None:
    local = conn.execute(
        "SELECT trust_status FROM node_capabilities WHERE identity_node_id = ?",
        (observer_node_id,),
    ).fetchone()
    instant = at_time or datetime.now(timezone.utc)
    denial = node_trust_denial_at(
        observer_node_id,
        at_time=instant,
        ledger_path=TRUST_LEDGER_DB_PATH,
    )
    current_denial = node_trust_denial_at(
        observer_node_id,
        at_time=policy_time or datetime.now(timezone.utc),
        ledger_path=TRUST_LEDGER_DB_PATH,
    )
    historical_before_denial = False
    if historical_event and denial is None and current_denial is not None:
        try:
            historical_before_denial = _parse_time(
                current_denial["decided_at"]
            ) > instant
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(
                status_code=503, detail="invalid local TrustRecord state"
            ) from exc
    if denial is not None:
        raise HTTPException(status_code=403, detail="observer is suspended or revoked")
    if (
        local is not None
        and (local["trust_status"] or "unknown") != "trusted"
        and not historical_before_denial
    ):
        raise HTTPException(status_code=403, detail="observer is not trusted")


def _pull_assignment_rows(
    conn: sqlite3.Connection,
    observer_node_id: str,
    *,
    current_iso: str,
    limit: int,
) -> list[dict[str, Any]]:
    conn.execute(
        """UPDATE challenge_assignment_observers
           SET state = 'expired'
           WHERE observer_node_id = ? AND state IN ('pending', 'accepted')
             AND assignment_id IN (
                 SELECT assignment_id FROM challenge_assignments WHERE expires_at < ?
             )""",
        (observer_node_id, current_iso),
    )
    rows = conn.execute(
        """SELECT a.assignment_json, o.state, o.ack_json,
                  o.completed_observation_id, o.completed_at
           FROM challenge_assignments AS a
           JOIN challenge_assignment_observers AS o
             ON o.assignment_id = a.assignment_id
           WHERE o.observer_node_id = ?
           ORDER BY a.epoch ASC, a.stored_at ASC LIMIT ?""",
        (observer_node_id, limit),
    ).fetchall()
    conn.commit()
    return [
        {
            "assignment": json.loads(row["assignment_json"]),
            "state": row["state"],
            "ack": json.loads(row["ack_json"]) if row["ack_json"] else None,
            "completed_observation_id": row["completed_observation_id"],
            "completed_at": row["completed_at"],
        }
        for row in rows
    ]


def publish_assignment(
    assignment: Mapping[str, Any],
    *,
    authority: CapabilityAuthorityState,
    now: datetime | None = None,
    require_registered_participants: bool = True,
) -> tuple[str, bool]:
    if not isinstance(assignment, Mapping):
        raise HTTPException(status_code=400, detail="assignment must be an object")
    try:
        serialized = canonical_json(dict(assignment))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="assignment must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_ASSIGNMENT_BYTES:
        raise HTTPException(status_code=413, detail="assignment exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    expected_observers = assignment.get("observer_node_ids", ())
    expected_randomness_commitment = None
    if RANDOMNESS_CHECKPOINT_MODE != "off":
        stored_randomness = randomness_checkpoint_by_hash(
            assignment.get("randomness_commitment", "")
        )
        if stored_randomness is None:
            if RANDOMNESS_CHECKPOINT_MODE == "enforce":
                raise HTTPException(
                    status_code=409,
                    detail="validated randomness checkpoint is unavailable",
                )
        else:
            checkpoint = stored_randomness["checkpoint"]
            if (
                checkpoint.get("challenge_epoch") != assignment.get("epoch")
                or checkpoint.get("authority_epoch")
                != assignment.get("authority_epoch")
            ):
                raise HTTPException(
                    status_code=400,
                    detail="assignment epoch does not match randomness checkpoint",
                )
            try:
                expected_observers = selected_observers_from_checkpoint(
                    checkpoint=checkpoint,
                    subject_node_id=assignment.get("subject_node_id"),
                    challenge_type=assignment.get("challenge_type"),
                )
            except (KeyError, TypeError, ValueError) as exc:
                raise HTTPException(
                    status_code=400,
                    detail=f"invalid randomness observer selection: {exc}",
                ) from exc
            expected_randomness_commitment = stored_randomness["checkpoint_hash"]
    validation = validate_challenge_assignment(
        assignment,
        now=current_time,
        # The quorum-signed assignment is the authority-approved observer set.
        # Independent deterministic selection is verified before validators sign.
        expected_observer_node_ids=expected_observers,
        expected_committee=authority.committee,
        expected_threshold=authority.threshold,
        validator_credentials=authority.validators,
        minimum_epoch=0,
        expected_authority_epoch=authority.epoch,
        expected_randomness_commitment=expected_randomness_commitment,
    )
    if not validation.valid:
        raise HTTPException(status_code=400, detail=validation.reason or "invalid assignment")
    if CHALLENGE_PROPOSAL_SCHEDULER_MODE != "off":
        from app.challenge_proposal_scheduler import assignment_matches_local_proposal

        proposal_matches = assignment_matches_local_proposal(dict(assignment))
        if not proposal_matches and CHALLENGE_PROPOSAL_SCHEDULER_MODE == "enforce":
            raise HTTPException(
                status_code=409,
                detail="assignment does not match deterministic local proposal",
            )

    assignment_id = assignment["assignment_id"]
    with get_conn() as conn:
        # Serialize chain-head validation with insertion. Without an immediate
        # write transaction, two concurrent epochs could both validate against
        # the same head and create a fork even though each row is individually
        # valid.
        conn.execute("BEGIN IMMEDIATE")
        if require_registered_participants:
            subject = conn.execute(
                "SELECT node_identity_status FROM node_capabilities WHERE identity_node_id = ?",
                (assignment["subject_node_id"],),
            ).fetchone()
            if subject is None or subject["node_identity_status"] != "valid":
                raise HTTPException(status_code=404, detail="unknown assignment subject")
            placeholders = ",".join("?" for _ in assignment["observer_node_ids"])
            observers = conn.execute(
                f"""SELECT identity_node_id, node_identity_status, trust_status
                    FROM node_capabilities WHERE identity_node_id IN ({placeholders})""",
                tuple(assignment["observer_node_ids"]),
            ).fetchall()
            eligible = {
                row["identity_node_id"]
                for row in observers
                if row["node_identity_status"] == "valid" and row["trust_status"] == "trusted"
            }
            if eligible != set(assignment["observer_node_ids"]):
                raise HTTPException(status_code=409, detail="assignment contains ineligible observer")

        existing = conn.execute(
            "SELECT assignment_json FROM challenge_assignments WHERE assignment_id = ?",
            (assignment_id,),
        ).fetchone()
        if existing is not None:
            if existing["assignment_json"] == serialized:
                return assignment_id, False
            raise AssignmentConflict("assignment_id equivocation")

        prior = conn.execute(
            """SELECT epoch, assignment_json FROM challenge_assignments
               WHERE subject_node_id = ? AND challenge_type = ? AND epoch < ?
               ORDER BY epoch DESC LIMIT 1""",
            (
                assignment["subject_node_id"],
                assignment["challenge_type"],
                assignment["epoch"],
            ),
        ).fetchone()
        expected_previous_hash = (
            challenge_assignment_hash(json.loads(prior["assignment_json"]))
            if prior is not None
            else None
        )
        if assignment["previous_hash"] != expected_previous_hash:
            raise HTTPException(
                status_code=409,
                detail="challenge assignment previous_hash does not match local chain",
            )
        later = conn.execute(
            """SELECT epoch FROM challenge_assignments
               WHERE subject_node_id = ? AND challenge_type = ? AND epoch > ?
               ORDER BY epoch ASC LIMIT 1""",
            (
                assignment["subject_node_id"],
                assignment["challenge_type"],
                assignment["epoch"],
            ),
        ).fetchone()
        if later is not None:
            raise HTTPException(
                status_code=409,
                detail="challenge assignment rollback detected",
            )
        try:
            conn.execute(
                """INSERT INTO challenge_assignments (
                       assignment_id, subject_node_id, challenge_type, epoch,
                       not_before, expires_at, assignment_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    assignment_id,
                    assignment["subject_node_id"],
                    assignment["challenge_type"],
                    assignment["epoch"],
                    assignment["not_before"],
                    assignment["expires_at"],
                    serialized,
                    _iso(current_time),
                ),
            )
            conn.executemany(
                """INSERT INTO challenge_assignment_observers (
                       assignment_id, observer_node_id, state
                   ) VALUES (?, ?, 'pending')""",
                [(assignment_id, observer_id) for observer_id in assignment["observer_node_ids"]],
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AssignmentConflict(
                "conflicting assignment for subject, challenge type and epoch"
            ) from exc
    return assignment_id, True


def list_assignments_after_sequence(
    *,
    after_sequence: int = 0,
    limit: int = 100,
) -> list[dict[str, Any]]:
    if (
        not isinstance(after_sequence, int)
        or isinstance(after_sequence, bool)
        or after_sequence < 0
    ):
        raise ValueError("after_sequence must be a non-negative integer")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT rowid AS sequence, assignment_json
               FROM challenge_assignments WHERE rowid > ?
               ORDER BY rowid ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {"sequence": row["sequence"], "assignment": json.loads(row["assignment_json"])}
        for row in rows
    ]


def latest_assignment_sequence() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(rowid), 0) AS sequence FROM challenge_assignments"
        ).fetchone()
    return int(row["sequence"])


def list_ack_events_after_sequence(
    *, after_sequence: int = 0, limit: int = 100
) -> list[dict[str, Any]]:
    if (
        not isinstance(after_sequence, int)
        or isinstance(after_sequence, bool)
        or after_sequence < 0
    ):
        raise ValueError("after_sequence must be a non-negative integer")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT sequence, ack_hash, ack_json, operational_certificate_json
               FROM challenge_assignment_ack_events WHERE sequence > ?
               ORDER BY sequence ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {
            "sequence": row["sequence"],
            "ack_hash": row["ack_hash"],
            "ack": json.loads(row["ack_json"]),
            "operational_certificate": json.loads(
                row["operational_certificate_json"]
            ),
        }
        for row in rows
    ]


def latest_ack_sequence() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS sequence "
            "FROM challenge_assignment_ack_events"
        ).fetchone()
    return int(row["sequence"])


def expire_assignment_observers(*, now: datetime | None = None) -> int:
    """Globally close expired jobs even when an observer never polls again."""
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    with get_conn() as conn:
        cursor = conn.execute(
            """UPDATE challenge_assignment_observers
               SET state = 'expired'
               WHERE state IN ('pending', 'accepted')
                 AND assignment_id IN (
                     SELECT assignment_id FROM challenge_assignments
                     WHERE expires_at < ?
                 )""",
            (_iso(current),),
        )
        conn.commit()
        return max(0, cursor.rowcount)


def _persist_ack_event(
    conn: sqlite3.Connection,
    *,
    ack: Mapping[str, Any],
    serialized_ack: str,
    operational_certificate: Mapping[str, Any],
    stored_at: datetime,
) -> bool:
    digest = challenge_assignment_ack_hash(ack)
    serialized_certificate = canonical_json(dict(operational_certificate))
    existing = conn.execute(
        """SELECT ack_hash, ack_json, operational_certificate_json
           FROM challenge_assignment_ack_events
           WHERE assignment_id = ? AND observer_node_id = ?""",
        (ack["assignment_id"], ack["observer_node_id"]),
    ).fetchone()
    if existing is not None:
        if (
            existing["ack_hash"] == digest
            and existing["ack_json"] == serialized_ack
            and existing["operational_certificate_json"] == serialized_certificate
        ):
            return False
        raise HTTPException(status_code=409, detail="assignment ack event conflict")
    conn.execute(
        """INSERT INTO challenge_assignment_ack_events (
               assignment_id, observer_node_id, ack_hash, ack_json,
               operational_certificate_json, stored_at
           ) VALUES (?, ?, ?, ?, ?, ?)""",
        (
            ack["assignment_id"],
            ack["observer_node_id"],
            digest,
            serialized_ack,
            serialized_certificate,
            _iso(stored_at),
        ),
    )
    return True


def pull_assignments(
    observer_node_id: str,
    *,
    authorization: str | None,
    now: datetime | None = None,
    limit: int = 20,
) -> list[dict[str, Any]]:
    if not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 100")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    current_iso = _iso(current_time)
    with get_conn() as conn:
        _observer_row(conn, observer_node_id, authorization)
        return _pull_assignment_rows(
            conn,
            observer_node_id,
            current_iso=current_iso,
            limit=limit,
        )


def pull_assignments_with_proof(
    proof: Mapping[str, Any],
    *,
    limit: int,
    operational_credential_state: Mapping[str, Any] | None = None,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    if not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 100")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    validation = validate_observer_request_proof(
        proof,
        action="challenge_assignment_pull",
        payload={"limit": limit},
        now=current_time,
    )
    if not validation.valid:
        raise HTTPException(status_code=401, detail=validation.reason or "invalid observer proof")
    admit_live_operational_credential(
        proof["operational_certificate"],
        operational_credential_state,
        mode=OPERATIONAL_CREDENTIAL_STATE_MODE,
        now=current_time,
    )
    with get_conn() as conn:
        require_portable_observer_allowed(conn, validation.observer_node_id)
        conn.execute(
            "DELETE FROM observer_request_nonces WHERE expires_at < ?",
            (_iso(current_time),),
        )
        try:
            conn.execute(
                """INSERT INTO observer_request_nonces
                   (request_nonce, observer_node_id, expires_at, consumed_at)
                   VALUES (?, ?, ?, ?)""",
                (
                    validation.request_nonce,
                    validation.observer_node_id,
                    proof["expires_at"],
                    _iso(current_time),
                ),
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="observer proof replay") from exc
        assignments = _pull_assignment_rows(
            conn,
            validation.observer_node_id,
            current_iso=_iso(current_time),
            limit=limit,
        )
    return assignments


def acknowledge_assignment(
    ack: Mapping[str, Any],
    *,
    authorization: str | None,
    observer_certificate: Mapping[str, Any] | None = None,
    operational_credential_state: Mapping[str, Any] | None = None,
    historical_event: bool = False,
    now: datetime | None = None,
) -> tuple[str, str, bool]:
    if not isinstance(ack, Mapping):
        raise HTTPException(status_code=400, detail="ack must be an object")
    try:
        serialized = canonical_json(dict(ack))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="ack must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_ACK_BYTES:
        raise HTTPException(status_code=413, detail="ack exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    assignment_id = ack.get("assignment_id")
    observer_node_id = ack.get("observer_node_id")
    if observer_certificate is not None and not historical_event:
        admit_live_operational_credential(
            observer_certificate,
            operational_credential_state,
            mode=OPERATIONAL_CREDENTIAL_STATE_MODE,
            now=current_time,
        )
    with get_conn() as conn:
        observer = None
        portable_credential = None
        if observer_certificate is None:
            observer = _observer_row(conn, observer_node_id, authorization)
            try:
                event_certificate = json.loads(observer["operational_certificate"])
            except (TypeError, json.JSONDecodeError) as exc:
                raise HTTPException(
                    status_code=403,
                    detail="invalid observer operational credential",
                ) from exc
        else:
            try:
                credential_validation_time = (
                    _parse_time(ack["acknowledged_at"])
                    if historical_event
                    else current_time
                )
            except (KeyError, TypeError, ValueError) as exc:
                raise HTTPException(status_code=400, detail="malformed ack time") from exc
            certificate_validation = validate_operational_certificate(
                observer_certificate,
                now=credential_validation_time,
            )
            if not certificate_validation.valid:
                raise HTTPException(
                    status_code=403,
                    detail=(
                        "invalid observer operational certificate: "
                        f"{certificate_validation.reason}"
                    ),
                )
            if observer_certificate.get("node_id") != observer_node_id:
                raise HTTPException(status_code=403, detail="observer certificate NodeID mismatch")
            require_portable_observer_allowed(
                conn,
                observer_node_id,
                at_time=credential_validation_time,
                historical_event=historical_event,
                policy_time=current_time,
            )
            portable_credential = ValidatorCredential(
                public_key=observer_certificate["operational_public_key"],
                valid_until=_parse_time(observer_certificate["valid_until"]),
            )
            event_certificate = observer_certificate
        row = conn.execute(
            """SELECT a.not_before, a.expires_at, o.state, o.ack_json
               FROM challenge_assignments AS a
               JOIN challenge_assignment_observers AS o
                 ON o.assignment_id = a.assignment_id
               WHERE a.assignment_id = ? AND o.observer_node_id = ?""",
            (assignment_id, observer_node_id),
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="assignment is not assigned to observer")
        try:
            if portable_credential is not None:
                credential = portable_credential
            else:
                certificate = json.loads(observer["operational_certificate"])
                credential = ValidatorCredential(
                    public_key=observer["signing_public_key"],
                    valid_until=_parse_time(certificate["valid_until"]),
                )
            not_before = _parse_time(row["not_before"])
            expires_at = _parse_time(row["expires_at"])
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise HTTPException(status_code=403, detail="invalid observer operational credential") from exc
        event_time = (
            _parse_time(ack["acknowledged_at"])
            if historical_event
            else current_time
        )
        require_operational_credential_not_revoked(
            event_certificate, at_time=event_time
        )
        validation = validate_assignment_ack(
            ack,
            now=event_time,
            expected_assignment_id=assignment_id,
            expected_observer_node_id=observer_node_id,
            observer_credential=credential,
            assignment_not_before=not_before,
            assignment_expires_at=expires_at,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason or "invalid assignment ack")
        target_state = ack["decision"]
        if row["ack_json"] == serialized and row["state"] in {
            target_state,
            "completed",
        }:
            _persist_ack_event(
                conn,
                ack=ack,
                serialized_ack=serialized,
                operational_certificate=event_certificate,
                stored_at=current_time,
            )
            conn.commit()
            return assignment_id, target_state, False
        if row["state"] != "pending":
            raise HTTPException(status_code=409, detail="assignment ack state conflict")
        conn.execute(
            """UPDATE challenge_assignment_observers
               SET state = ?, ack_json = ?, acknowledged_at = ?
               WHERE assignment_id = ? AND observer_node_id = ?""",
            (
                target_state,
                serialized,
                ack["acknowledged_at"],
                assignment_id,
                observer_node_id,
            ),
        )
        _persist_ack_event(
            conn,
            ack=ack,
            serialized_ack=serialized,
            operational_certificate=event_certificate,
            stored_at=current_time,
        )
        conn.commit()
    return assignment_id, target_state, True


def complete_assignment_from_observation(
    conn: sqlite3.Connection,
    *,
    assignment_id: str,
    observation: Mapping[str, Any],
    completed_at: datetime,
) -> None:
    row = conn.execute(
        """SELECT a.subject_node_id, a.challenge_type, a.epoch,
                  a.not_before, a.expires_at, o.state, o.completed_observation_id
           FROM challenge_assignments AS a
           JOIN challenge_assignment_observers AS o
             ON o.assignment_id = a.assignment_id
           WHERE a.assignment_id = ? AND o.observer_node_id = ?""",
        (assignment_id, observation["observer_node_id"]),
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="observation assignment link is unknown")
    if row["state"] == "completed":
        if row["completed_observation_id"] == observation["observation_id"]:
            return
        raise HTTPException(status_code=409, detail="assignment already completed by another observation")
    if row["state"] != "accepted":
        raise HTTPException(status_code=409, detail="assignment must be accepted before completion")
    if (
        row["subject_node_id"] != observation["subject_node_id"]
        or row["challenge_type"] != observation["challenge_type"]
        or row["epoch"] != observation["epoch"]
    ):
        raise HTTPException(status_code=409, detail="observation does not match assignment")
    observed_at = _parse_time(observation["observed_at"])
    if observed_at + CLOCK_SKEW < _parse_time(row["not_before"]):
        raise HTTPException(status_code=409, detail="observation predates assignment")
    if observed_at - CLOCK_SKEW > _parse_time(row["expires_at"]):
        raise HTTPException(status_code=409, detail="observation is after assignment expiry")
    conn.execute(
        """UPDATE challenge_assignment_observers
           SET state = 'completed', completed_observation_id = ?, completed_at = ?
           WHERE assignment_id = ? AND observer_node_id = ?""",
        (
            observation["observation_id"],
            _iso(completed_at),
            assignment_id,
            observation["observer_node_id"],
        ),
    )
