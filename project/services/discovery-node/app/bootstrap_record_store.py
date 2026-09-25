"""Persistent monotonic cache for endpoint-signed BootstrapRecords."""

import json
from datetime import datetime, timezone
from typing import Any, Mapping

from app.db import get_conn
from shared.security.bootstrap_record import validate_bootstrap_record


class BootstrapRecordConflict(ValueError):
    pass


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def publish_bootstrap_record(
    record: Mapping[str, Any], *, now: datetime | None = None
) -> dict[str, Any]:
    if not isinstance(record, Mapping):
        raise ValueError("BootstrapRecord must be an object")
    user_id = record.get("user_id")
    if not isinstance(user_id, str) or not user_id:
        raise ValueError("BootstrapRecord user_id is required")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    normalized = json.dumps(dict(record), sort_keys=True, separators=(",", ":"))
    with get_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        existing = conn.execute(
            "SELECT * FROM bootstrap_records WHERE user_id = ?", (user_id,)
        ).fetchone()
        validation = validate_bootstrap_record(
            record,
            now=current_time,
            minimum_identity_version=existing["identity_version"] if existing else 1,
            minimum_record_version=existing["record_version"] if existing else 1,
        )
        if not validation.valid:
            raise ValueError(validation.reason or "invalid BootstrapRecord")
        if existing and record["record_version"] == existing["record_version"]:
            if normalized != existing["record_json"]:
                raise BootstrapRecordConflict(
                    "conflicting BootstrapRecord at the same version"
                )
            return {
                "record": json.loads(existing["record_json"]),
                "stored_at": existing["stored_at"],
                "accepted": False,
            }
        if existing and record["record_version"] != existing["record_version"] + 1:
            raise BootstrapRecordConflict(
                "BootstrapRecord version must be consecutive"
            )
        stored_at = _iso(current_time)
        conn.execute(
            """INSERT INTO bootstrap_records (
                   user_id, identity_version, record_version, record_json,
                   expires_at, stored_at
               ) VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                   identity_version=excluded.identity_version,
                   record_version=excluded.record_version,
                   record_json=excluded.record_json,
                   expires_at=excluded.expires_at,
                   stored_at=excluded.stored_at""",
            (
                user_id,
                record["identity_version"],
                record["record_version"],
                normalized,
                record["expires_at"],
                stored_at,
            ),
        )
        conn.commit()
    return {"record": dict(record), "stored_at": stored_at, "accepted": True}


def list_bootstrap_records(*, after_user_id: str = "", limit: int = 100) -> list[dict]:
    if not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT record_json FROM bootstrap_records
               WHERE user_id > ? ORDER BY user_id ASC LIMIT ?""",
            (after_user_id, limit),
        ).fetchall()
    return [json.loads(row["record_json"]) for row in rows]
