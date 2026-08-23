"""Validation and bounded persistence for externally signed Trust observations."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from app.config import OPERATIONAL_CREDENTIAL_STATE_MODE
from app.operational_credential_store import admit_live_operational_credential
from app.operational_credential_revocation_store import (
    require_operational_credential_not_revoked,
)
from app.challenge_assignment_store import (
    complete_assignment_from_observation,
    require_portable_observer_allowed,
)
from app.security import verify_hash
from app.trust import enrollment_required
from shared.security.canonical import canonical_json
from shared.security.node_identity import validate_operational_certificate
from shared.security.trust_evidence import (
    ObserverCredential,
    trust_observation_hash,
    validate_reliability_observation,
)


MAX_OBSERVATION_BYTES = 16 * 1024
MAX_ACTIVE_OBSERVATIONS_PER_OBSERVER = 1_000
EXPIRED_RETENTION = timedelta(days=7)


def _parse_time(value: str) -> datetime:
    return datetime.fromisoformat(
        value[:-1] + "+00:00" if value.endswith("Z") else value
    ).astimezone(timezone.utc)


def _bearer_token(value: str | None) -> str | None:
    if not isinstance(value, str) or not value.startswith("Bearer "):
        return None
    token = value[7:].strip()
    return token or None


def list_observation_events_after_sequence(
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
            """SELECT sequence, assignment_id, observation_hash,
                      observation_json, operational_certificate_json
               FROM trust_observation_events WHERE sequence > ?
               ORDER BY sequence ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {
            "sequence": row["sequence"],
            "assignment_id": row["assignment_id"],
            "observation_hash": row["observation_hash"],
            "observation": json.loads(row["observation_json"]),
            "operational_certificate": json.loads(
                row["operational_certificate_json"]
            ),
        }
        for row in rows
    ]


def latest_observation_event_sequence() -> int:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COALESCE(MAX(sequence), 0) AS sequence "
            "FROM trust_observation_events"
        ).fetchone()
    return int(row["sequence"])


def _persist_observation_event(
    conn: sqlite3.Connection,
    *,
    assignment_id: str,
    observation: Mapping[str, Any],
    serialized_observation: str,
    operational_certificate: Mapping[str, Any],
    stored_at: datetime,
) -> bool:
    digest = trust_observation_hash(observation)
    serialized_certificate = canonical_json(dict(operational_certificate))
    existing = conn.execute(
        """SELECT assignment_id, observation_hash, observation_json,
                  operational_certificate_json
           FROM trust_observation_events WHERE observation_id = ?""",
        (observation["observation_id"],),
    ).fetchone()
    if existing is not None:
        if (
            existing["assignment_id"] == assignment_id
            and existing["observation_hash"] == digest
            and existing["observation_json"] == serialized_observation
            and existing["operational_certificate_json"] == serialized_certificate
        ):
            return False
        raise HTTPException(status_code=409, detail="TrustObservation event conflict")
    try:
        conn.execute(
            """INSERT INTO trust_observation_events (
                   observation_id, assignment_id, observer_node_id,
                   observation_hash, observation_json,
                   operational_certificate_json, stored_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                observation["observation_id"],
                assignment_id,
                observation["observer_node_id"],
                digest,
                serialized_observation,
                serialized_certificate,
                stored_at.isoformat().replace("+00:00", "Z"),
            ),
        )
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="TrustObservation event conflict") from exc
    return True


def publish_observation(
    observation: Mapping,
    *,
    authorization: str | None,
    assignment_id: str | None = None,
    observer_certificate: Mapping[str, Any] | None = None,
    operational_credential_state: Mapping[str, Any] | None = None,
    historical_event: bool = False,
    now: datetime | None = None,
) -> tuple[str, bool]:
    if not isinstance(observation, Mapping):
        raise HTTPException(status_code=400, detail="observation must be an object")
    try:
        serialized = canonical_json(dict(observation))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="observation must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_OBSERVATION_BYTES:
        raise HTTPException(status_code=413, detail="observation exceeds size limit")

    observer_node_id = observation.get("observer_node_id")
    subject_node_id = observation.get("subject_node_id")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    current_iso = current_time.isoformat().replace("+00:00", "Z")
    retention_cutoff = (current_time - EXPIRED_RETENTION).isoformat().replace("+00:00", "Z")

    if observer_certificate is not None and not historical_event:
        admit_live_operational_credential(
            observer_certificate,
            operational_credential_state,
            mode=OPERATIONAL_CREDENTIAL_STATE_MODE,
            now=current_time,
        )

    with get_conn() as conn:
        if observer_certificate is None:
            observer = conn.execute(
                "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
                (observer_node_id,),
            ).fetchone()
            if observer is None or observer["node_identity_status"] != "valid":
                raise HTTPException(status_code=403, detail="unknown observer Node Identity")
            if (observer["trust_status"] or "unknown") != "trusted":
                raise HTTPException(status_code=403, detail="observer is not trusted")
            if observer["node_token_hash"] and enrollment_required():
                if not verify_hash(_bearer_token(authorization) or "", observer["node_token_hash"]):
                    raise HTTPException(status_code=401, detail="invalid or missing observer node_token")
            subject = conn.execute(
                """SELECT node_id, node_identity_status FROM node_capabilities
                   WHERE identity_node_id = ?""",
                (subject_node_id,),
            ).fetchone()
            if subject is None or subject["node_identity_status"] != "valid":
                raise HTTPException(status_code=404, detail="unknown subject Node Identity")
            try:
                event_certificate = json.loads(observer["operational_certificate"])
                credential = ObserverCredential(
                    public_key=observer["signing_public_key"],
                    valid_until=_parse_time(event_certificate["valid_until"]),
                )
            except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
                raise HTTPException(
                    status_code=403,
                    detail="invalid observer operational credential",
                ) from exc
        else:
            if not assignment_id:
                raise HTTPException(
                    status_code=400,
                    detail="portable observation requires assignment_id",
                )
            try:
                credential_validation_time = (
                    _parse_time(observation["observed_at"])
                    if historical_event
                    else current_time
                )
            except (KeyError, TypeError, ValueError) as exc:
                raise HTTPException(
                    status_code=400,
                    detail="malformed observation time",
                ) from exc
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
                raise HTTPException(
                    status_code=403,
                    detail="observer certificate NodeID mismatch",
                )
            require_portable_observer_allowed(
                conn,
                observer_node_id,
                at_time=credential_validation_time,
                historical_event=historical_event,
                policy_time=current_time,
            )
            event_certificate = observer_certificate
            credential = ObserverCredential(
                public_key=observer_certificate["operational_public_key"],
                valid_until=_parse_time(observer_certificate["valid_until"]),
            )

        event_time = (
            _parse_time(observation["observed_at"])
            if historical_event
            else current_time
        )
        require_operational_credential_not_revoked(
            event_certificate, at_time=event_time
        )

        conn.execute("DELETE FROM trust_observations WHERE expires_at < ?", (retention_cutoff,))
        observation_id = observation.get("observation_id")
        existing = conn.execute(
            "SELECT observation_json FROM trust_observations WHERE observation_id = ?",
            (observation_id,),
        ).fetchone()
        if existing is not None:
            if existing["observation_json"] == serialized:
                if assignment_id:
                    complete_assignment_from_observation(
                        conn,
                        assignment_id=assignment_id,
                        observation=observation,
                        completed_at=current_time,
                    )
                    _persist_observation_event(
                        conn,
                        assignment_id=assignment_id,
                        observation=observation,
                        serialized_observation=serialized,
                        operational_certificate=event_certificate,
                        stored_at=current_time,
                    )
                    conn.commit()
                return observation_id, False
            raise HTTPException(status_code=409, detail="observation_id equivocation")
        commitment_replay = conn.execute(
            """SELECT observation_id FROM trust_observations
               WHERE observer_node_id = ? AND challenge_commitment = ?""",
            (observer_node_id, observation.get("challenge_commitment")),
        ).fetchone()
        if commitment_replay is not None:
            raise HTTPException(status_code=409, detail="challenge observation replay")
        active_count = conn.execute(
            "SELECT COUNT(*) FROM trust_observations WHERE observer_node_id = ? AND expires_at >= ?",
            (observer_node_id, current_iso),
        ).fetchone()[0]
        if active_count >= MAX_ACTIVE_OBSERVATIONS_PER_OBSERVER:
            raise HTTPException(status_code=429, detail="observer active evidence quota exceeded")

        validation = validate_reliability_observation(
            observation,
            now=event_time,
            observer_credentials={
                observer_node_id: credential
            },
            expected_subject_node_id=subject_node_id,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason or "invalid observation")

        if assignment_id:
            complete_assignment_from_observation(
                conn,
                assignment_id=assignment_id,
                observation=observation,
                completed_at=current_time,
            )

        try:
            conn.execute(
                """
                INSERT INTO trust_observations (
                    observation_id, observer_node_id, subject_node_id, epoch,
                    challenge_type, challenge_commitment, result, latency_bucket,
                    observed_at, expires_at, observation_json, stored_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    observation_id,
                    observer_node_id,
                    subject_node_id,
                    observation["epoch"],
                    observation["challenge_type"],
                    observation["challenge_commitment"],
                    observation["result"],
                    observation["latency_bucket"],
                    observation["observed_at"],
                    observation["expires_at"],
                    serialized,
                    current_iso,
                ),
            )
            if assignment_id:
                _persist_observation_event(
                    conn,
                    assignment_id=assignment_id,
                    observation=observation,
                    serialized_observation=serialized,
                    operational_certificate=event_certificate,
                    stored_at=current_time,
                )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="challenge observation replay") from exc
    return observation_id, True


def list_observations(subject_node_id: str, *, limit: int = 100) -> list[dict]:
    if not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 100")
    current_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT observation_json FROM trust_observations
            WHERE subject_node_id = ? AND expires_at >= ?
            ORDER BY observed_at DESC LIMIT ?
            """,
            (subject_node_id, current_iso, limit),
        ).fetchall()
    return [json.loads(row["observation_json"]) for row in rows]
