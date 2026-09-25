"""Per-hop cell metadata for authenticated Basic Transport links."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping


PROTOCOL_VERSION = "ouo-link-cell/1"
FIELDS = {"protocol_version", "cell_id", "created_at", "expires_at", "payload"}
MAX_TTL_SECONDS = 300


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def build_link_cell(payload: Mapping[str, Any], *, ttl_seconds: int = 60) -> dict[str, Any]:
    if not isinstance(payload, Mapping):
        raise ValueError("link cell payload must be an object")
    if not isinstance(ttl_seconds, int) or isinstance(ttl_seconds, bool) or not 1 <= ttl_seconds <= MAX_TTL_SECONDS:
        raise ValueError("invalid link cell TTL")
    now = datetime.now(timezone.utc)
    return {
        "protocol_version": PROTOCOL_VERSION,
        "cell_id": str(uuid.uuid4()),
        "created_at": _iso(now),
        "expires_at": _iso(now + timedelta(seconds=ttl_seconds)),
        "payload": dict(payload),
    }


def validate_link_cell(cell: Mapping[str, Any], *, now: datetime) -> str | None:
    if not isinstance(cell, Mapping) or set(cell) != FIELDS:
        return "invalid link cell fields"
    if cell.get("protocol_version") != PROTOCOL_VERSION:
        return "unsupported link cell protocol_version"
    try:
        if str(uuid.UUID(cell["cell_id"])) != cell["cell_id"]:
            return "invalid link cell ID"
    except (AttributeError, TypeError, ValueError):
        return "invalid link cell ID"
    if not isinstance(cell.get("payload"), Mapping):
        return "invalid link cell payload"
    try:
        created_text = cell["created_at"]
        expires_text = cell["expires_at"]
        created = datetime.fromisoformat(
            created_text[:-1] + "+00:00" if created_text.endswith("Z") else created_text
        )
        expires = datetime.fromisoformat(
            expires_text[:-1] + "+00:00" if expires_text.endswith("Z") else expires_text
        )
    except (AttributeError, TypeError, ValueError):
        return "invalid link cell timestamps"
    if created.tzinfo is None or expires.tzinfo is None or now.tzinfo is None:
        return "link cell timestamps must include timezone"
    lifetime = (expires - created).total_seconds()
    if not 0 < lifetime <= MAX_TTL_SECONDS:
        return "invalid link cell lifetime"
    current = now.astimezone(timezone.utc)
    if current < created.astimezone(timezone.utc) - timedelta(seconds=30):
        return "link cell is not yet valid"
    if current > expires.astimezone(timezone.utc):
        return "link cell expired"
    return None
