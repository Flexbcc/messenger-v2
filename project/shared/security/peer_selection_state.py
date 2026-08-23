"""Private selection seed and bounded persistent guard-state helpers."""

from __future__ import annotations

import base64
import json
import os
import secrets
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlsplit

from shared.security.canonical import canonical_json
from shared.security.node_identity import NODE_ID_PREFIX


SEED_BYTES = 32
MAX_STATE_BYTES = 262144
STATE_VERSION = 1


def _decode_seed(text: str) -> bytes:
    try:
        raw = base64.b64decode(text.strip().encode("ascii"), altchars=b"-_", validate=True)
    except Exception as exc:
        raise ValueError("peer selection seed is not valid base64url") from exc
    if len(raw) != SEED_BYTES:
        raise ValueError("peer selection seed must contain exactly 32 bytes")
    return raw


def load_or_create_selection_seed(path: str) -> bytes:
    target = Path(path)
    try:
        return _decode_seed(target.read_text(encoding="utf-8"))
    except FileNotFoundError:
        pass
    target.parent.mkdir(parents=True, exist_ok=True)
    raw = secrets.token_bytes(SEED_BYTES)
    encoded = base64.urlsafe_b64encode(raw).decode("ascii")
    try:
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return _decode_seed(target.read_text(encoding="utf-8"))
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    return raw


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("peer state timestamp must be a string")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("peer state timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def validate_peer_selection_state(state: Mapping[str, Any], *, now: datetime) -> dict[str, Any]:
    if not isinstance(state, Mapping) or set(state) != {
        "state_version",
        "selection_epoch",
        "guards",
        "rotating",
        "reserves",
        "updated_at",
        "valid_until",
    }:
        raise ValueError("invalid peer selection state fields")
    if state.get("state_version") != STATE_VERSION:
        raise ValueError("unsupported peer selection state version")
    epoch = state.get("selection_epoch")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("invalid peer selection epoch")
    seen: set[str] = set()
    normalized = dict(state)
    for bucket, maximum in (("guards", 5), ("rotating", 14), ("reserves", 15)):
        entries = state.get(bucket)
        if not isinstance(entries, list) or len(entries) > maximum:
            raise ValueError(f"invalid {bucket} peer state")
        for entry in entries:
            if not isinstance(entry, Mapping) or set(entry) != {
                "node_id",
                "endpoint",
                "diversity_group",
            }:
                raise ValueError(f"invalid {bucket} peer entry")
            if any(
                not isinstance(entry[field], str)
                or not entry[field]
                or len(entry[field]) > 2048
                for field in ("node_id", "endpoint", "diversity_group")
            ):
                raise ValueError(f"invalid {bucket} peer entry")
            endpoint = urlsplit(entry["endpoint"])
            if (
                not entry["node_id"].startswith(NODE_ID_PREFIX)
                or endpoint.scheme != "https"
                or not endpoint.hostname
                or endpoint.username
                or endpoint.password
                or endpoint.query
                or endpoint.fragment
            ):
                raise ValueError(f"invalid {bucket} peer entry")
            if entry["node_id"] in seen:
                raise ValueError("duplicate node across peer selection buckets")
            seen.add(entry["node_id"])
    updated = _parse_time(state["updated_at"])
    valid_until = _parse_time(state["valid_until"])
    if valid_until <= updated:
        raise ValueError("invalid peer selection state lifetime")
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("validation time must be timezone-aware")
    if now.astimezone(timezone.utc) > valid_until:
        raise ValueError("peer selection state has expired")
    return normalized


def load_peer_selection_state(path: str, *, now: datetime) -> dict[str, Any] | None:
    try:
        raw = Path(path).read_bytes()
    except FileNotFoundError:
        return None
    if len(raw) > MAX_STATE_BYTES:
        raise ValueError("peer selection state exceeds size limit")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("peer selection state is not valid JSON") from exc
    return validate_peer_selection_state(data, now=now)


def save_peer_selection_state(path: str, state: Mapping[str, Any], *, now: datetime) -> None:
    validated = validate_peer_selection_state(state, now=now)
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    serialized = canonical_json(validated)
    if len(serialized.encode("utf-8")) > MAX_STATE_BYTES:
        raise ValueError("peer selection state exceeds size limit")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
