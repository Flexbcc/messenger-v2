"""Persistent validated AuthorityCheckpoint chain for Discovery."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from fastapi import HTTPException

from app.db import get_conn
from shared.security.authority_checkpoint import (
    authority_checkpoint_hash,
    authority_state_from_checkpoint,
    authority_state_hash,
    validate_authority_checkpoint,
)
from shared.security.authority_gossip import validate_authority_announcement
from shared.security.authority_recovery import (
    authority_recovery_hash,
    replacement_checkpoint_hash,
    validate_authority_recovery,
)
from shared.security.canonical import canonical_json
from shared.security.capability_certificate import (
    ValidatorCredential,
    validate_capability_certificate,
)
from shared.security.capability_enrollment import (
    CapabilityAuthorityState,
    load_capability_authority_state,
)


MAX_CHECKPOINT_BYTES = 128 * 1024
MAX_RECOVERY_BYTES = 256 * 1024
MAX_ANNOUNCEMENT_BYTES = 16 * 1024
MAX_ACTIVE_ANNOUNCEMENTS_PER_SOURCE = 100
ANNOUNCEMENT_RETENTION = timedelta(days=1)


class AuthorityCheckpointConflict(RuntimeError):
    """Two different quorum checkpoints claim the same authority epoch."""


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _latest_row(conn: sqlite3.Connection):
    return conn.execute(
        """SELECT authority_epoch, checkpoint_hash, previous_hash,
                  checkpoint_json, stored_at
           FROM authority_checkpoints ORDER BY authority_epoch DESC LIMIT 1"""
    ).fetchone()


def _latest_recovery_row(conn: sqlite3.Connection):
    return conn.execute(
        """SELECT authority_epoch, recovery_hash, replacement_checkpoint_hash,
                  compromised_authority_epoch, recovery_json,
                  replacement_checkpoint_json, stored_at
           FROM authority_recoveries ORDER BY authority_epoch DESC LIMIT 1"""
    ).fetchone()


def _effective_head(conn: sqlite3.Connection) -> dict[str, Any] | None:
    normal = _latest_row(conn)
    recovery = _latest_recovery_row(conn)
    if recovery is not None and (
        normal is None or recovery["authority_epoch"] >= normal["authority_epoch"]
    ):
        return {
            "authority_epoch": recovery["authority_epoch"],
            "checkpoint_hash": recovery["replacement_checkpoint_hash"],
            "checkpoint_json": recovery["replacement_checkpoint_json"],
            "stored_at": recovery["stored_at"],
            "kind": "recovery",
        }
    if normal is None:
        return None
    return {
        "authority_epoch": normal["authority_epoch"],
        "checkpoint_hash": normal["checkpoint_hash"],
        "checkpoint_json": normal["checkpoint_json"],
        "stored_at": normal["stored_at"],
        "kind": "normal",
    }


def _effective_head_before(
    conn: sqlite3.Connection,
    authority_epoch: int,
) -> dict[str, Any] | None:
    normal = conn.execute(
        """SELECT authority_epoch, checkpoint_hash, checkpoint_json, stored_at
           FROM authority_checkpoints WHERE authority_epoch < ?
           ORDER BY authority_epoch DESC LIMIT 1""",
        (authority_epoch,),
    ).fetchone()
    recovery = conn.execute(
        """SELECT authority_epoch, replacement_checkpoint_hash,
                  replacement_checkpoint_json, stored_at
           FROM authority_recoveries WHERE authority_epoch < ?
           ORDER BY authority_epoch DESC LIMIT 1""",
        (authority_epoch,),
    ).fetchone()
    if recovery is not None and (
        normal is None or recovery["authority_epoch"] >= normal["authority_epoch"]
    ):
        return {
            "authority_epoch": recovery["authority_epoch"],
            "checkpoint_hash": recovery["replacement_checkpoint_hash"],
            "checkpoint_json": recovery["replacement_checkpoint_json"],
            "stored_at": recovery["stored_at"],
            "kind": "recovery",
        }
    if normal is None:
        return None
    return {
        "authority_epoch": normal["authority_epoch"],
        "checkpoint_hash": normal["checkpoint_hash"],
        "checkpoint_json": normal["checkpoint_json"],
        "stored_at": normal["stored_at"],
        "kind": "normal",
    }


def latest_checkpoint() -> dict[str, Any] | None:
    with get_conn() as conn:
        row = _effective_head(conn)
    if row is None:
        return None
    return {
        "checkpoint": json.loads(row["checkpoint_json"]),
        "checkpoint_hash": row["checkpoint_hash"],
        "stored_at": row["stored_at"],
    }


def list_checkpoints(*, after_epoch: int = -1, limit: int = 20) -> list[dict[str, Any]]:
    if not isinstance(after_epoch, int) or isinstance(after_epoch, bool) or after_epoch < -1:
        raise HTTPException(status_code=400, detail="after_epoch must be at least -1")
    if not 1 <= limit <= 100:
        raise HTTPException(status_code=400, detail="limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT checkpoint_json, checkpoint_hash, stored_at
               FROM authority_checkpoints WHERE authority_epoch > ?
               ORDER BY authority_epoch ASC LIMIT ?""",
            (after_epoch, limit),
        ).fetchall()
    return [
        {
            "checkpoint": json.loads(row["checkpoint_json"]),
            "checkpoint_hash": row["checkpoint_hash"],
            "stored_at": row["stored_at"],
        }
        for row in rows
    ]


def load_effective_authority_state(
    path: str,
    *,
    bootstrap_state: CapabilityAuthorityState | None = None,
) -> CapabilityAuthorityState | None:
    bootstrap = (
        bootstrap_state
        if bootstrap_state is not None
        else load_capability_authority_state(path)
    )
    with get_conn() as conn:
        row = _effective_head(conn)
    if row is None:
        return bootstrap
    checkpoint = json.loads(row["checkpoint_json"])
    return authority_state_from_checkpoint(checkpoint)


def load_authority_state_at_epoch(
    path: str,
    authority_epoch: int,
    *,
    bootstrap_state: CapabilityAuthorityState | None = None,
) -> CapabilityAuthorityState | None:
    """Return the exact authority set that governed one signed object epoch.

    Historical TrustRecords must be checked against their own authority epoch,
    not whatever committee happens to be current when a Discovery replica first
    receives them.
    """
    if (
        not isinstance(authority_epoch, int)
        or isinstance(authority_epoch, bool)
        or authority_epoch < 0
    ):
        return None
    bootstrap = (
        bootstrap_state
        if bootstrap_state is not None
        else load_capability_authority_state(path)
    )
    with get_conn() as conn:
        recovery = conn.execute(
            """SELECT replacement_checkpoint_json FROM authority_recoveries
               WHERE authority_epoch = ?""",
            (authority_epoch,),
        ).fetchone()
        if recovery is not None:
            return authority_state_from_checkpoint(
                json.loads(recovery["replacement_checkpoint_json"])
            )
        checkpoint = conn.execute(
            """SELECT checkpoint_json FROM authority_checkpoints
               WHERE authority_epoch = ?""",
            (authority_epoch,),
        ).fetchone()
    if checkpoint is not None:
        return authority_state_from_checkpoint(json.loads(checkpoint["checkpoint_json"]))
    if bootstrap is not None and bootstrap.epoch == authority_epoch:
        return bootstrap
    return None


def publish_authority_checkpoint(
    checkpoint: Mapping[str, Any],
    *,
    bootstrap_state: CapabilityAuthorityState,
    now: datetime | None = None,
) -> tuple[str, bool]:
    if not isinstance(checkpoint, Mapping):
        raise HTTPException(status_code=400, detail="checkpoint must be an object")
    try:
        serialized = canonical_json(dict(checkpoint))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="checkpoint must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_CHECKPOINT_BYTES:
        raise HTTPException(status_code=413, detail="checkpoint exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)

    with get_conn() as conn:
        claimed_epoch = checkpoint.get("authority_epoch")
        if isinstance(claimed_epoch, int) and not isinstance(claimed_epoch, bool):
            existing = conn.execute(
                "SELECT checkpoint_hash, checkpoint_json FROM authority_checkpoints WHERE authority_epoch = ?",
                (claimed_epoch,),
            ).fetchone()
            if existing is not None:
                try:
                    digest = authority_checkpoint_hash(checkpoint)
                except (KeyError, TypeError, ValueError):
                    digest = None
                if existing["checkpoint_hash"] == digest and existing["checkpoint_json"] == serialized:
                    return existing["checkpoint_hash"], False
                raise AuthorityCheckpointConflict("authority checkpoint epoch equivocation")
            recovery_at_epoch = conn.execute(
                "SELECT recovery_hash FROM authority_recoveries WHERE authority_epoch = ?",
                (claimed_epoch,),
            ).fetchone()
            if recovery_at_epoch is not None:
                raise AuthorityCheckpointConflict(
                    "normal checkpoint conflicts with emergency recovery epoch"
                )
        latest = _effective_head(conn)
        if latest is None:
            previous_state = bootstrap_state
            expected_previous_hash = authority_state_hash(bootstrap_state)
        else:
            previous_checkpoint = json.loads(latest["checkpoint_json"])
            previous_state = authority_state_from_checkpoint(previous_checkpoint)
            expected_previous_hash = latest["checkpoint_hash"]
        validation = validate_authority_checkpoint(
            checkpoint,
            now=current_time,
            previous_state=previous_state,
            expected_previous_hash=expected_previous_hash,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason or "invalid checkpoint")

        digest = authority_checkpoint_hash(checkpoint)
        try:
            conn.execute(
                """INSERT INTO authority_checkpoints (
                       authority_epoch, checkpoint_hash, previous_hash,
                       checkpoint_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?)""",
                (
                    checkpoint["authority_epoch"],
                    digest,
                    checkpoint["previous_hash"],
                    serialized,
                    _iso(current_time),
                ),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AuthorityCheckpointConflict("authority checkpoint conflict") from exc
    return digest, True


def publish_authority_recovery(
    recovery: Mapping[str, Any],
    *,
    recovery_state: CapabilityAuthorityState,
    bootstrap_state: CapabilityAuthorityState,
    minimum_authority_epoch: int,
    now: datetime | None = None,
) -> tuple[str, str, int, bool]:
    if not isinstance(recovery, Mapping):
        raise HTTPException(status_code=400, detail="recovery must be an object")
    try:
        serialized = canonical_json(dict(recovery))
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="recovery must be canonical JSON") from exc
    if len(serialized.encode("utf-8")) > MAX_RECOVERY_BYTES:
        raise HTTPException(status_code=413, detail="recovery exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    replacement = recovery.get("replacement_checkpoint")
    claimed_epoch = replacement.get("authority_epoch") if isinstance(replacement, Mapping) else None

    with get_conn() as conn:
        head = _effective_head(conn)
        local_epoch = head["authority_epoch"] if head is not None else bootstrap_state.epoch
        required_epoch = max(minimum_authority_epoch, local_epoch)
        validation = validate_authority_recovery(
            recovery,
            now=current_time,
            recovery_state=recovery_state,
            minimum_authority_epoch=required_epoch,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason or "invalid recovery")
        recovery_digest = authority_recovery_hash(recovery)
        replacement_digest = replacement_checkpoint_hash(recovery)
        existing = conn.execute(
            """SELECT recovery_hash, replacement_checkpoint_hash, recovery_json
               FROM authority_recoveries WHERE authority_epoch = ?""",
            (claimed_epoch,),
        ).fetchone()
        if existing is not None:
            if (
                existing["recovery_hash"] == recovery_digest
                and existing["replacement_checkpoint_hash"] == replacement_digest
                and existing["recovery_json"] == serialized
            ):
                return recovery_digest, replacement_digest, claimed_epoch, False
            raise AuthorityCheckpointConflict("authority recovery epoch equivocation")
        normal_at_epoch = conn.execute(
            "SELECT checkpoint_hash FROM authority_checkpoints WHERE authority_epoch = ?",
            (claimed_epoch,),
        ).fetchone()
        if normal_at_epoch is not None:
            raise AuthorityCheckpointConflict(
                "emergency recovery conflicts with normal checkpoint epoch"
            )
        try:
            conn.execute(
                """INSERT INTO authority_recoveries (
                       authority_epoch, recovery_hash,
                       replacement_checkpoint_hash, compromised_authority_epoch,
                       recovery_json, replacement_checkpoint_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    claimed_epoch,
                    recovery_digest,
                    replacement_digest,
                    recovery["compromised_authority_epoch"],
                    serialized,
                    canonical_json(dict(replacement)),
                    _iso(current_time),
                ),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AuthorityCheckpointConflict("authority recovery conflict") from exc
    return recovery_digest, replacement_digest, claimed_epoch, True


def ingest_authority_gossip(
    checkpoint: Mapping[str, Any],
    announcement: Mapping[str, Any],
    *,
    bootstrap_state: CapabilityAuthorityState,
    now: datetime | None = None,
) -> tuple[str, bool, bool, str]:
    """Authenticate a Discovery source, validate quorum state, then persist both."""
    if not isinstance(announcement, Mapping):
        raise HTTPException(status_code=400, detail="announcement must be an object")
    try:
        announcement_json = canonical_json(dict(announcement))
        digest = authority_checkpoint_hash(checkpoint)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid gossip object") from exc
    if len(announcement_json.encode("utf-8")) > MAX_ANNOUNCEMENT_BYTES:
        raise HTTPException(status_code=413, detail="announcement exceeds size limit")
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    source_node_id = announcement.get("source_node_id")
    checkpoint_known = False

    with get_conn() as conn:
        source = conn.execute(
            "SELECT * FROM node_capabilities WHERE identity_node_id = ?",
            (source_node_id,),
        ).fetchone()
        if source is None or source["node_identity_status"] != "valid":
            raise HTTPException(status_code=403, detail="unknown gossip source Node Identity")
        if (source["trust_status"] or "unknown") != "trusted":
            raise HTTPException(status_code=403, detail="gossip source is not trusted")
        known_normal = conn.execute(
            "SELECT checkpoint_hash FROM authority_checkpoints WHERE authority_epoch = ?",
            (checkpoint.get("authority_epoch"),),
        ).fetchone()
        known_recovery = conn.execute(
            """SELECT replacement_checkpoint_hash FROM authority_recoveries
               WHERE authority_epoch = ?""",
            (checkpoint.get("authority_epoch"),),
        ).fetchone()
        known_hashes = {
            row_hash
            for row_hash in (
                known_normal["checkpoint_hash"] if known_normal is not None else None,
                known_recovery["replacement_checkpoint_hash"]
                if known_recovery is not None
                else None,
            )
            if row_hash is not None
        }
        if known_hashes and digest not in known_hashes:
            raise AuthorityCheckpointConflict(
                "gossip checkpoint conflicts with locally known epoch"
            )
        checkpoint_known = digest in known_hashes
        try:
            capability_certificate = json.loads(source["capability_certificate"])
        except (TypeError, json.JSONDecodeError):
            capability_certificate = None
        latest_authority = _effective_head(conn)
        effective_authority = (
            authority_state_from_checkpoint(json.loads(latest_authority["checkpoint_json"]))
            if latest_authority is not None
            else bootstrap_state
        )
        authority_candidates = [effective_authority]
        if checkpoint_known:
            announced_authority = authority_state_from_checkpoint(checkpoint)
            if announced_authority not in authority_candidates:
                authority_candidates.append(announced_authority)
        # During one checkpoint transition, collect independent announcements
        # from Discovery nodes whose capability was valid under the immediately
        # previous authority. This overlap is bounded by the signed gossip TTL.
        if (
            latest_authority is not None
            and latest_authority["authority_epoch"] == checkpoint.get("authority_epoch")
        ):
            previous_row = _effective_head_before(
                conn, latest_authority["authority_epoch"]
            )
            authority_candidates.append(
                authority_state_from_checkpoint(json.loads(previous_row["checkpoint_json"]))
                if previous_row is not None
                else bootstrap_state
            )
        capability_valid = False
        if isinstance(capability_certificate, Mapping):
            for candidate_authority in authority_candidates:
                capability_validation = validate_capability_certificate(
                    capability_certificate,
                    now=current_time,
                    expected_committee=candidate_authority.committee,
                    expected_threshold=candidate_authority.threshold,
                    validator_credentials=candidate_authority.validators,
                    minimum_epoch=0,
                    expected_authority_epoch=candidate_authority.epoch,
                    expected_subject_node_id=source_node_id,
                )
                if capability_validation.valid:
                    capability_valid = True
                    break
        if (
            source["capability_certificate_status"] != "valid"
            or not capability_valid
            or "discovery" not in capability_certificate.get("capabilities", [])
        ):
            raise HTTPException(
                status_code=403,
                detail="gossip source lacks a currently valid Discovery capability",
            )
        try:
            operational_certificate = json.loads(source["operational_certificate"])
            source_credential = ValidatorCredential(
                public_key=source["signing_public_key"],
                valid_until=datetime.fromisoformat(
                    operational_certificate["valid_until"][:-1] + "+00:00"
                    if operational_certificate["valid_until"].endswith("Z")
                    else operational_certificate["valid_until"]
                ),
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise HTTPException(status_code=403, detail="invalid gossip source credential") from exc
        validation = validate_authority_announcement(
            announcement,
            now=current_time,
            expected_checkpoint_hash=digest,
            expected_authority_epoch=checkpoint.get("authority_epoch"),
            source_credential=source_credential,
        )
        if not validation.valid:
            raise HTTPException(status_code=400, detail=validation.reason or "invalid announcement")

        existing = conn.execute(
            "SELECT announcement_json FROM authority_checkpoint_announcements WHERE announcement_id = ?",
            (announcement["announcement_id"],),
        ).fetchone()
        if existing is not None:
            if existing["announcement_json"] == announcement_json:
                return digest, False, False, source_node_id
            raise AuthorityCheckpointConflict("authority announcement equivocation")
        retention_cutoff = _iso(current_time - ANNOUNCEMENT_RETENTION)
        conn.execute(
            "DELETE FROM authority_checkpoint_announcements WHERE expires_at < ?",
            (retention_cutoff,),
        )
        active_count = conn.execute(
            """SELECT COUNT(*) FROM authority_checkpoint_announcements
               WHERE source_node_id = ? AND expires_at >= ?""",
            (source_node_id, _iso(current_time)),
        ).fetchone()[0]
        if active_count >= MAX_ACTIVE_ANNOUNCEMENTS_PER_SOURCE:
            raise HTTPException(status_code=429, detail="gossip source announcement quota exceeded")

    if checkpoint_known:
        checkpoint_accepted = False
    else:
        digest, checkpoint_accepted = publish_authority_checkpoint(
            checkpoint,
            bootstrap_state=bootstrap_state,
            now=current_time,
        )
    with get_conn() as conn:
        try:
            conn.execute(
                """INSERT INTO authority_checkpoint_announcements (
                       announcement_id, source_node_id, authority_epoch,
                       checkpoint_hash, expires_at, announcement_json, stored_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    announcement["announcement_id"],
                    source_node_id,
                    announcement["authority_epoch"],
                    digest,
                    announcement["expires_at"],
                    announcement_json,
                    _iso(current_time),
                ),
            )
            conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AuthorityCheckpointConflict("authority announcement conflict") from exc
    return digest, checkpoint_accepted, True, source_node_id
