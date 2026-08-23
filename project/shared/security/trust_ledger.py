"""Quorum-signed OUO Trust Ledger v1 and a small SQLite reference store."""

import copy
import hashlib
import json
import re
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence

from nacl.signing import SigningKey

from shared.security.canonical import canonical_json
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import sign_message, verify_message
from shared.security.node_identity import NODE_ID_PREFIX


PROTOCOL_VERSION = "ouo-trust-record/1"
OBJECT_VERSION = 1
SIGNING_DOMAIN = b"OUO/TRUST_RECORD/v1\x00"
CLOCK_SKEW = timedelta(minutes=5)
MAX_RECORD_BYTES = 65536
ACTIONS = frozenset(
    {"promotion", "degradation", "suspension", "reinstatement", "revocation"}
)
_SIGNED_FIELDS = {
    "protocol_version",
    "object_version",
    "record_id",
    "subject_node_id",
    "previous_level",
    "new_level",
    "action",
    "epoch",
    "authority_epoch",
    "metrics_commitment",
    "committee",
    "threshold",
    "previous_hash",
    "decided_at",
}
_ALL_FIELDS = _SIGNED_FIELDS | {"signatures"}


@dataclass(frozen=True)
class TrustRecordValidation:
    valid: bool
    reason: Optional[str] = None
    valid_signatures: int = 0


class TrustLedgerConflict(ValueError):
    pass


def _utc_iso(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def trust_record_signing_payload(record: Mapping[str, Any]) -> bytes:
    signed = {field: record[field] for field in _SIGNED_FIELDS}
    return SIGNING_DOMAIN + canonical_json(signed).encode("utf-8")


def trust_record_hash(record: Mapping[str, Any]) -> str:
    return hashlib.sha256(canonical_json(dict(record)).encode("utf-8")).hexdigest()


def build_trust_record(
    *,
    subject_node_id: str,
    previous_level: int,
    new_level: int,
    action: str,
    epoch: int,
    authority_epoch: int | None = None,
    metrics_commitment: str,
    committee: Sequence[str],
    threshold: int,
    previous_hash: Optional[str],
    decided_at: datetime,
    record_id: Optional[str] = None,
) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "object_version": OBJECT_VERSION,
        "record_id": record_id or str(uuid.uuid4()),
        "subject_node_id": subject_node_id,
        "previous_level": previous_level,
        "new_level": new_level,
        "action": action,
        "epoch": epoch,
        "authority_epoch": epoch if authority_epoch is None else authority_epoch,
        "metrics_commitment": metrics_commitment,
        "committee": sorted(committee),
        "threshold": threshold,
        "previous_hash": previous_hash,
        "decided_at": _utc_iso(decided_at),
        "signatures": [],
    }


def add_trust_record_signature(
    record: Mapping[str, Any],
    *,
    validator_id: str,
    validator_signing_key: SigningKey,
) -> dict[str, Any]:
    result = copy.deepcopy(dict(record))
    result.setdefault("signatures", []).append(
        {
            "validator_id": validator_id,
            "signature": sign_message(validator_signing_key, trust_record_signing_payload(result)),
        }
    )
    result["signatures"] = sorted(result["signatures"], key=lambda item: item["validator_id"])
    return result


def _semantic_error(record: Mapping[str, Any]) -> Optional[str]:
    if set(record) != _ALL_FIELDS:
        return "invalid trust record fields"
    if record.get("protocol_version") != PROTOCOL_VERSION or record.get("object_version") != OBJECT_VERSION:
        return "unsupported trust record version"
    try:
        if str(uuid.UUID(record["record_id"])) != record["record_id"]:
            return "invalid record_id"
    except (AttributeError, TypeError, ValueError):
        return "invalid record_id"
    subject = record.get("subject_node_id")
    if not isinstance(subject, str) or not subject.startswith(NODE_ID_PREFIX):
        return "invalid subject_node_id"
    previous_level = record.get("previous_level")
    new_level = record.get("new_level")
    if any(
        not isinstance(level, int) or isinstance(level, bool) or not 0 <= level <= 5
        for level in (previous_level, new_level)
    ):
        return "invalid trust level"
    action = record.get("action")
    if action not in ACTIONS:
        return "invalid trust action"
    if action == "promotion" and not new_level > previous_level:
        return "promotion must increase level"
    if action == "degradation" and not new_level < previous_level:
        return "degradation must decrease level"
    if action == "suspension" and new_level != previous_level:
        return "suspension must preserve level"
    if action == "reinstatement" and new_level != previous_level:
        return "reinstatement must preserve level"
    if action == "revocation" and new_level != 0:
        return "revocation must return node to L0"
    epoch = record.get("epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        return "invalid epoch"
    authority_epoch = record.get("authority_epoch")
    if (
        not isinstance(authority_epoch, int)
        or isinstance(authority_epoch, bool)
        or authority_epoch < 0
    ):
        return "invalid authority_epoch"
    if not isinstance(record.get("metrics_commitment"), str) or re.fullmatch(
        r"[0-9a-f]{64}", record["metrics_commitment"]
    ) is None:
        return "invalid metrics_commitment"
    committee = record.get("committee")
    if (
        not isinstance(committee, list)
        or any(not isinstance(item, str) or not item for item in committee)
        or committee != sorted(set(committee))
        or not committee
    ):
        return "invalid committee"
    threshold = record.get("threshold")
    if not isinstance(threshold, int) or isinstance(threshold, bool) or not 1 <= threshold <= len(committee):
        return "invalid threshold"
    previous_hash = record.get("previous_hash")
    if previous_hash is not None and (
        not isinstance(previous_hash, str) or re.fullmatch(r"[0-9a-f]{64}", previous_hash) is None
    ):
        return "invalid previous_hash"
    if not isinstance(record.get("signatures"), list):
        return "invalid signatures"
    return None


def validate_trust_record(
    record: Mapping[str, Any],
    *,
    now: datetime,
    expected_committee: Sequence[str],
    expected_threshold: int,
    validator_credentials: Mapping[str, ValidatorCredential],
    minimum_epoch: int = 0,
    expected_epoch: int | None = None,
    expected_authority_epoch: int | None = None,
) -> TrustRecordValidation:
    if not isinstance(record, Mapping):
        return TrustRecordValidation(False, "trust record must be an object")
    try:
        if len(canonical_json(dict(record)).encode("utf-8")) > MAX_RECORD_BYTES:
            return TrustRecordValidation(False, "trust record exceeds size limit")
    except (TypeError, ValueError):
        return TrustRecordValidation(False, "trust record is not valid JSON")
    error = _semantic_error(record)
    if error:
        return TrustRecordValidation(False, error)
    if record["committee"] != sorted(set(expected_committee)):
        return TrustRecordValidation(False, "committee does not match externally selected committee")
    if record["threshold"] != expected_threshold:
        return TrustRecordValidation(False, "threshold does not match authority policy")
    if record["epoch"] < minimum_epoch:
        return TrustRecordValidation(False, "trust record rollback detected")
    if expected_epoch is not None and record["epoch"] != expected_epoch:
        return TrustRecordValidation(
            False, "trust record epoch does not match authority epoch"
        )
    if (
        expected_authority_epoch is not None
        and record["authority_epoch"] != expected_authority_epoch
    ):
        return TrustRecordValidation(
            False, "TrustRecord authority_epoch does not match authority state"
        )
    if now.tzinfo is None or now.utcoffset() is None:
        return TrustRecordValidation(False, "validation time must be timezone-aware")
    try:
        decided_at = _parse_time(record["decided_at"])
    except (TypeError, ValueError):
        return TrustRecordValidation(False, "malformed decision time")
    now_utc = now.astimezone(timezone.utc)
    if decided_at > now_utc + CLOCK_SKEW:
        return TrustRecordValidation(False, "trust decision is from the future")

    payload = trust_record_signing_payload(record)
    seen: set[str] = set()
    valid_count = 0
    for entry in record["signatures"]:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"validator_id", "signature"}
            or not isinstance(entry["validator_id"], str)
            or not isinstance(entry["signature"], str)
        ):
            return TrustRecordValidation(False, "malformed validator signature", valid_count)
        validator_id = entry["validator_id"]
        if validator_id in seen:
            return TrustRecordValidation(False, "duplicate validator signature", valid_count)
        seen.add(validator_id)
        if validator_id not in record["committee"]:
            return TrustRecordValidation(False, "signature from validator outside committee", valid_count)
        credential = validator_credentials.get(validator_id)
        if credential is None or credential.revoked:
            continue
        if credential.valid_until.tzinfo is None or credential.valid_until.utcoffset() is None:
            continue
        if credential.valid_until.astimezone(timezone.utc) < decided_at:
            continue
        if verify_message(credential.public_key, payload, entry["signature"]):
            valid_count += 1
    if valid_count < expected_threshold:
        return TrustRecordValidation(False, "insufficient valid validator signatures", valid_count)
    return TrustRecordValidation(True, valid_signatures=valid_count)


def equivocation_signers(first: Mapping[str, Any], second: Mapping[str, Any]) -> tuple[str, ...]:
    if (
        first.get("subject_node_id") != second.get("subject_node_id")
        or first.get("epoch") != second.get("epoch")
        or trust_record_hash(first) == trust_record_hash(second)
    ):
        return ()
    first_signers = {
        item.get("validator_id") for item in first.get("signatures", []) if isinstance(item, dict)
    }
    second_signers = {
        item.get("validator_id") for item in second.get("signatures", []) if isinstance(item, dict)
    }
    return tuple(sorted((first_signers & second_signers) - {None}))


class TrustLedgerStore:
    def __init__(self, path: str):
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                """CREATE TABLE IF NOT EXISTS trust_records (
                    subject_node_id TEXT NOT NULL,
                    epoch INTEGER NOT NULL,
                    record_hash TEXT NOT NULL UNIQUE,
                    previous_hash TEXT,
                    record_json TEXT NOT NULL,
                    PRIMARY KEY(subject_node_id, epoch)
                )"""
            )
            conn.execute(
                """CREATE TABLE IF NOT EXISTS trust_equivocation_evidence (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    subject_node_id TEXT NOT NULL,
                    epoch INTEGER NOT NULL,
                    existing_record_hash TEXT NOT NULL,
                    conflicting_record_hash TEXT NOT NULL,
                    conflicting_record_json TEXT NOT NULL,
                    detected_at TEXT NOT NULL
                )"""
            )

    def _connect(self):
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def contains_hash(self, record_hash: str) -> bool:
        with self._connect() as conn:
            return conn.execute(
                "SELECT 1 FROM trust_records WHERE record_hash = ?", (record_hash,)
            ).fetchone() is not None

    def contains_subject_epoch(self, subject_node_id: str, epoch: int) -> bool:
        with self._connect() as conn:
            return conn.execute(
                "SELECT 1 FROM trust_records WHERE subject_node_id = ? AND epoch = ?",
                (subject_node_id, epoch),
            ).fetchone() is not None

    def append_validated(
        self,
        record: Mapping[str, Any],
        *,
        now: datetime,
        expected_committee: Sequence[str],
        expected_threshold: int,
        validator_credentials: Mapping[str, ValidatorCredential],
        minimum_epoch: int = 0,
        expected_epoch: int | None = None,
        expected_authority_epoch: int | None = None,
    ) -> bool:
        validation = validate_trust_record(
            record,
            now=now,
            expected_committee=expected_committee,
            expected_threshold=expected_threshold,
            validator_credentials=validator_credentials,
            minimum_epoch=minimum_epoch,
            expected_epoch=expected_epoch,
            expected_authority_epoch=expected_authority_epoch,
        )
        if not validation.valid:
            raise ValueError(f"invalid TrustRecord: {validation.reason}")
        serialized = canonical_json(dict(record))
        digest = trust_record_hash(record)
        subject = record["subject_node_id"]
        epoch = record["epoch"]
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT record_hash FROM trust_records WHERE subject_node_id = ? AND epoch = ?",
                (subject, epoch),
            ).fetchone()
            if existing:
                if existing["record_hash"] == digest:
                    return False
                duplicate_evidence = conn.execute(
                    """SELECT 1 FROM trust_equivocation_evidence
                       WHERE subject_node_id = ? AND epoch = ?
                         AND existing_record_hash = ?
                         AND conflicting_record_hash = ?""",
                    (subject, epoch, existing["record_hash"], digest),
                ).fetchone()
                if duplicate_evidence is not None:
                    raise TrustLedgerConflict(
                        "conflicting TrustRecord for subject and epoch"
                    )
                conn.execute(
                    """INSERT INTO trust_equivocation_evidence (
                        subject_node_id, epoch, existing_record_hash,
                        conflicting_record_hash, conflicting_record_json, detected_at
                    ) VALUES (?, ?, ?, ?, ?, ?)""",
                    (subject, epoch, existing["record_hash"], digest, serialized, _utc_iso(now)),
                )
                conn.commit()
                raise TrustLedgerConflict("conflicting TrustRecord for subject and epoch")
            latest = conn.execute(
                """SELECT epoch, record_hash, record_json FROM trust_records
                   WHERE subject_node_id = ? ORDER BY epoch DESC LIMIT 1""",
                (subject,),
            ).fetchone()
            if latest is None:
                if record["previous_hash"] is not None:
                    raise ValueError("first TrustRecord must start with previous_hash=null")
                if record["action"] == "reinstatement":
                    raise ValueError("reinstatement requires a preceding suspension")
            else:
                if epoch != latest["epoch"] + 1:
                    raise ValueError("TrustRecord subject epoch must be consecutive")
                if record["previous_hash"] != latest["record_hash"]:
                    raise ValueError("TrustRecord previous_hash does not match ledger head")
                latest_record = json.loads(latest["record_json"])
                if record["previous_level"] != latest_record["new_level"]:
                    raise ValueError("TrustRecord previous_level does not match ledger head")
                if latest_record["action"] == "revocation":
                    raise ValueError("revocation is terminal in TrustRecord v1")
                if (
                    latest_record["action"] == "suspension"
                    and record["action"] not in {"reinstatement", "revocation"}
                ):
                    raise ValueError(
                        "suspension can only advance to reinstatement or revocation"
                    )
                if (
                    record["action"] == "reinstatement"
                    and latest_record["action"] != "suspension"
                ):
                    raise ValueError("reinstatement requires a preceding suspension")
            conn.execute(
                """INSERT INTO trust_records (
                    subject_node_id, epoch, record_hash, previous_hash, record_json
                ) VALUES (?, ?, ?, ?, ?)""",
                (subject, epoch, digest, record["previous_hash"], serialized),
            )
            conn.commit()
        return True

    def records(self, subject_node_id: str) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT record_json FROM trust_records WHERE subject_node_id = ? ORDER BY epoch",
                (subject_node_id,),
            ).fetchall()
        return [json.loads(row["record_json"]) for row in rows]

    def latest_record(self, subject_node_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            row = conn.execute(
                """SELECT record_json FROM trust_records
                   WHERE subject_node_id = ? ORDER BY epoch DESC LIMIT 1""",
                (subject_node_id,),
            ).fetchone()
        return json.loads(row["record_json"]) if row is not None else None

    def records_after_sequence(
        self,
        *,
        after_sequence: int = 0,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """List append-only rows for replication; SQLite rowid is a local cursor."""
        if (
            not isinstance(after_sequence, int)
            or isinstance(after_sequence, bool)
            or after_sequence < 0
        ):
            raise ValueError("after_sequence must be a non-negative integer")
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("limit must be between 1 and 100")
        with self._connect() as conn:
            rows = conn.execute(
                """SELECT rowid AS sequence, record_hash, record_json
                   FROM trust_records WHERE rowid > ? ORDER BY rowid ASC LIMIT ?""",
                (after_sequence, limit),
            ).fetchall()
        return [
            {
                "sequence": row["sequence"],
                "record_hash": row["record_hash"],
                "record": json.loads(row["record_json"]),
            }
            for row in rows
        ]

    def latest_sequence(self) -> int:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COALESCE(MAX(rowid), 0) AS sequence FROM trust_records"
            ).fetchone()
        return int(row["sequence"])

    def equivocation_count(self) -> int:
        with self._connect() as conn:
            return conn.execute("SELECT COUNT(*) FROM trust_equivocation_evidence").fetchone()[0]

    def equivocation_evidence(self, *, limit: int = 1000) -> list[dict[str, Any]]:
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 1000:
            raise ValueError("limit must be between 1 and 1000")
        with self._connect() as conn:
            rows = conn.execute(
                """SELECT e.subject_node_id, e.epoch,
                          e.existing_record_hash, e.conflicting_record_hash,
                          e.conflicting_record_json, e.detected_at,
                          r.record_json AS existing_record_json
                   FROM trust_equivocation_evidence AS e
                   JOIN trust_records AS r
                     ON r.record_hash = e.existing_record_hash
                   ORDER BY e.id DESC LIMIT ?""",
                (limit,),
            ).fetchall()
        result = []
        for row in rows:
            existing = json.loads(row["existing_record_json"])
            conflicting = json.loads(row["conflicting_record_json"])
            result.append(
                {
                    "subject_node_id": row["subject_node_id"],
                    "epoch": row["epoch"],
                    "existing_record_hash": row["existing_record_hash"],
                    "conflicting_record_hash": row["conflicting_record_hash"],
                    "detected_at": row["detected_at"],
                    "existing_record": existing,
                    "conflicting_record": conflicting,
                    "equivocating_validators": list(
                        equivocation_signers(existing, conflicting)
                    ),
                }
            )
        return result
