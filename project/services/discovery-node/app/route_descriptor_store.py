"""Persistent cache for endpoint-signed RouteDescriptor objects.

Discovery verifies and distributes the user's object. It never creates,
rewrites, or signs a route and therefore is not a route authority.
"""

import json
from datetime import datetime, timezone
from typing import Any, Mapping

from app.db import get_conn
from shared.security.route_descriptor import (
    route_descriptor_hash,
    validate_route_descriptor,
    validate_route_transition,
)


class RouteDescriptorConflict(ValueError):
    pass


class RouteDescriptorIdentityUnavailable(ValueError):
    pass


def _now_iso(now: datetime) -> str:
    return now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def publish_route_descriptor(
    descriptor: Mapping[str, Any], *, now: datetime | None = None
) -> dict[str, Any]:
    if not isinstance(descriptor, Mapping):
        raise ValueError("RouteDescriptor must be an object")
    user_id = descriptor.get("user_id")
    if not isinstance(user_id, str) or not user_id:
        raise ValueError("RouteDescriptor user_id is required")
    current_time = now or datetime.now(timezone.utc)
    normalized = json.dumps(dict(descriptor), sort_keys=True, separators=(",", ":"))

    with get_conn() as conn:
        # Serialize validation and insert so concurrent writers cannot both
        # pass the same highest-epoch check.
        conn.execute("BEGIN IMMEDIATE")
        bootstrap_row = conn.execute(
            "SELECT record_json FROM bootstrap_records WHERE user_id = ?",
            (user_id,),
        ).fetchone()
        if not bootstrap_row:
            raise RouteDescriptorIdentityUnavailable(
                "validated BootstrapRecord is required before RouteDescriptor"
            )
        bootstrap = json.loads(bootstrap_row["record_json"])
        identity_version = descriptor.get("identity_version")
        if identity_version != bootstrap.get("identity_version"):
            raise ValueError("RouteDescriptor identity_version does not match BootstrapRecord")

        previous_row = conn.execute(
            """SELECT descriptor_json, identity_version, route_epoch
               FROM route_descriptors
               WHERE user_id = ?
               ORDER BY route_epoch DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        minimum_epoch = previous_row["route_epoch"] if previous_row else 0
        validation = validate_route_descriptor(
            descriptor,
            identity_public_key=bootstrap["identity_public_key"],
            expected_user_id=user_id,
            now=current_time,
            minimum_identity_version=bootstrap["identity_version"],
            minimum_route_epoch=minimum_epoch,
            allow_future=True,
        )
        if not validation.valid:
            raise ValueError(validation.reason or "invalid RouteDescriptor")

        digest = route_descriptor_hash(descriptor)
        if previous_row and descriptor["route_epoch"] == previous_row["route_epoch"]:
            previous = json.loads(previous_row["descriptor_json"])
            if normalized != json.dumps(
                previous, sort_keys=True, separators=(",", ":")
            ):
                raise RouteDescriptorConflict(
                    "conflicting RouteDescriptor at the same route_epoch"
                )
            return {
                "user_id": user_id,
                "route_epoch": descriptor["route_epoch"],
                "descriptor_hash": digest,
                "accepted": False,
            }

        if previous_row:
            previous = json.loads(previous_row["descriptor_json"])
            transition = validate_route_transition(previous, descriptor)
            if not transition.valid:
                raise RouteDescriptorConflict(
                    transition.reason or "invalid RouteDescriptor transition"
                )

        conn.execute(
            """INSERT INTO route_descriptors (
                   user_id, identity_version, route_epoch, descriptor_hash,
                   descriptor_json, valid_from, valid_until, stored_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                user_id,
                descriptor["identity_version"],
                descriptor["route_epoch"],
                digest,
                normalized,
                descriptor["valid_from"],
                descriptor["valid_until"],
                _now_iso(current_time),
            ),
        )
        # Recovery only needs current/next/next+1. Older route history is
        # metadata and is deliberately not retained indefinitely.
        conn.execute(
            "DELETE FROM route_descriptors WHERE user_id = ? AND route_epoch < ?",
            (user_id, descriptor["route_epoch"] - 2),
        )
        conn.commit()
    return {
        "user_id": user_id,
        "route_epoch": descriptor["route_epoch"],
        "descriptor_hash": digest,
        "accepted": True,
    }


def list_route_descriptors(user_id: str, *, limit: int = 3) -> list[dict[str, Any]]:
    bounded_limit = max(1, min(limit, 3))
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT descriptor_json FROM route_descriptors
               WHERE user_id = ? ORDER BY route_epoch DESC LIMIT ?""",
            (user_id, bounded_limit),
        ).fetchall()
    return [json.loads(row["descriptor_json"]) for row in reversed(rows)]


def list_route_descriptor_gossip(
    *, after_sequence: int = 0, limit: int = 100
) -> list[dict[str, Any]]:
    if after_sequence < 0:
        raise ValueError("after_sequence must be non-negative")
    if not 1 <= limit <= 100:
        raise ValueError("limit must be between 1 and 100")
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT rowid AS sequence, descriptor_json
               FROM route_descriptors WHERE rowid > ?
               ORDER BY rowid ASC LIMIT ?""",
            (after_sequence, limit),
        ).fetchall()
    return [
        {
            "sequence": int(row["sequence"]),
            "descriptor": json.loads(row["descriptor_json"]),
        }
        for row in rows
    ]
