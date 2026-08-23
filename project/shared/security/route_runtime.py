"""Endpoint route resolution across independent, untrusted Discovery caches.

Discovery is a transport for endpoint-signed objects, never the route
authority.  This module validates every object locally, detects split views,
persists anti-rollback high-watermarks and exposes only currently usable
ingress descriptors.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from shared.security.bootstrap_record import validate_bootstrap_record
from shared.security.canonical import canonical_json
from shared.security.route_descriptor import (
    route_descriptor_hash,
    validate_route_descriptor,
    validate_route_transition,
)


STATE_VERSION = 1
MAX_STATE_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class RouteResolution:
    user_id: str
    identity_version: int
    record_version: int
    highest_route_epoch: int
    active_descriptor: Mapping[str, Any]
    future_descriptors: tuple[Mapping[str, Any], ...]
    agreeing_sources: tuple[str, ...]

    @property
    def ingress_set(self) -> tuple[Mapping[str, str], ...]:
        return tuple(self.active_descriptor["ingress_set"])


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("route timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _read_state(path: str) -> dict[str, Any]:
    target = Path(path)
    if not target.exists():
        return {"state_version": STATE_VERSION, "users": {}}
    raw = target.read_bytes()
    if len(raw) > MAX_STATE_BYTES:
        raise ValueError("route runtime state exceeds size limit")
    try:
        state = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("route runtime state is not valid JSON") from exc
    if (
        not isinstance(state, dict)
        or set(state) != {"state_version", "users"}
        or state.get("state_version") != STATE_VERSION
        or not isinstance(state.get("users"), dict)
    ):
        raise ValueError("invalid route runtime state")
    return state


def _write_state(path: str, state: Mapping[str, Any]) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = (canonical_json(dict(state)) + "\n").encode("utf-8")
    if len(payload) > MAX_STATE_BYTES:
        raise ValueError("route runtime state exceeds size limit")
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _select_quorum_object(
    objects: Sequence[tuple[str, Mapping[str, Any]]],
    *,
    version_field: str,
    minimum_sources: int,
) -> tuple[Mapping[str, Any], tuple[str, ...]]:
    if minimum_sources < 1:
        raise ValueError("minimum_sources must be positive")
    by_version: dict[int, dict[str, list[tuple[str, Mapping[str, Any]]]]] = {}
    for source, value in objects:
        version = value.get(version_field)
        if not isinstance(version, int) or isinstance(version, bool):
            continue
        encoded = canonical_json(dict(value))
        by_version.setdefault(version, {}).setdefault(encoded, []).append((source, value))
    for version in sorted(by_version, reverse=True):
        variants = by_version[version]
        if len(variants) > 1:
            raise ValueError(f"conflicting {version_field} {version} across Discovery sources")
        agreeing = next(iter(variants.values()))
        unique_sources = tuple(sorted({source for source, _value in agreeing}))
        if len(unique_sources) >= minimum_sources:
            return agreeing[0][1], unique_sources
    raise ValueError("independent Discovery quorum is unavailable")


def resolve_route_view(
    *,
    user_id: str,
    source_views: Sequence[tuple[str, Mapping[str, Any], Sequence[Mapping[str, Any]]]],
    state_path: str,
    now: datetime,
    minimum_sources: int = 2,
) -> RouteResolution:
    """Validate and aggregate `(source, bootstrap, descriptors)` responses."""
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("validation time must be timezone-aware")
    state = _read_state(state_path)
    previous = state["users"].get(user_id, {})
    minimum_identity = int(previous.get("identity_version", 1))
    minimum_record = int(previous.get("record_version", 1))
    highest_seen_route = int(previous.get("route_epoch", 0))
    # Discovery intentionally retains only current/next/next+1.  Once a
    # future epoch becomes the high-watermark, its two predecessors still
    # have to validate so the active route and its chain can be reconstructed.
    minimum_route = max(0, highest_seen_route - 2)

    bootstraps: list[tuple[str, Mapping[str, Any]]] = []
    for source, bootstrap, _descriptors in source_views:
        validation = validate_bootstrap_record(
            bootstrap,
            now=now,
            minimum_identity_version=minimum_identity,
            minimum_record_version=minimum_record,
        )
        if validation.valid and bootstrap.get("user_id") == user_id:
            bootstraps.append((source, bootstrap))
    bootstrap, bootstrap_sources = _select_quorum_object(
        bootstraps,
        version_field="record_version",
        minimum_sources=minimum_sources,
    )

    route_objects: list[tuple[str, Mapping[str, Any]]] = []
    source_filter = set(bootstrap_sources)
    for source, source_bootstrap, descriptors in source_views:
        if source not in source_filter or canonical_json(dict(source_bootstrap)) != canonical_json(dict(bootstrap)):
            continue
        for descriptor in descriptors:
            validation = validate_route_descriptor(
                descriptor,
                identity_public_key=bootstrap["identity_public_key"],
                expected_user_id=user_id,
                now=now,
                minimum_identity_version=bootstrap["identity_version"],
                minimum_route_epoch=minimum_route,
                allow_future=True,
            )
            if validation.valid:
                route_objects.append((source, descriptor))
    highest, route_sources = _select_quorum_object(
        route_objects,
        version_field="route_epoch",
        minimum_sources=minimum_sources,
    )

    versions: dict[int, dict[str, list[tuple[str, Mapping[str, Any]]]]] = {}
    for source, descriptor in route_objects:
        epoch = descriptor["route_epoch"]
        encoded = canonical_json(dict(descriptor))
        versions.setdefault(epoch, {}).setdefault(encoded, []).append((source, descriptor))
    agreed_by_epoch: dict[int, Mapping[str, Any]] = {}
    for epoch, variants in versions.items():
        if len(variants) > 1:
            raise ValueError(f"conflicting route_epoch {epoch} across Discovery sources")
        observations = next(iter(variants.values()))
        if len({source for source, _descriptor in observations}) >= minimum_sources:
            agreed_by_epoch[epoch] = observations[0][1]
    ordered = [agreed_by_epoch[epoch] for epoch in sorted(agreed_by_epoch)]
    for current, following in zip(ordered, ordered[1:]):
        transition = validate_route_transition(current, following)
        if not transition.valid:
            raise ValueError(transition.reason or "invalid route transition")

    now_utc = now.astimezone(timezone.utc)
    active = [
        descriptor
        for descriptor in ordered
        if _parse_time(descriptor["valid_from"]) <= now_utc <= _parse_time(descriptor["valid_until"])
    ]
    if not active:
        raise ValueError("no active RouteDescriptor in agreed route window")
    active_descriptor = max(active, key=lambda item: item["route_epoch"])
    future = tuple(
        descriptor
        for descriptor in ordered
        if descriptor["route_epoch"] > active_descriptor["route_epoch"]
    )[:2]

    highest_epoch = highest["route_epoch"]
    if highest_epoch < highest_seen_route:
        raise ValueError("RouteDescriptor high-watermark rollback")
    state["users"][user_id] = {
        "identity_version": bootstrap["identity_version"],
        "record_version": bootstrap["record_version"],
        "route_epoch": highest_epoch,
        "route_hash": route_descriptor_hash(highest),
    }
    _write_state(state_path, state)
    return RouteResolution(
        user_id=user_id,
        identity_version=bootstrap["identity_version"],
        record_version=bootstrap["record_version"],
        highest_route_epoch=highest_epoch,
        active_descriptor=active_descriptor,
        future_descriptors=future,
        agreeing_sources=route_sources,
    )
