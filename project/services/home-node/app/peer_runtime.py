"""Opt-in signed D1/D2/D3 peer selection for Home relay fallback."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import httpx
from shared.security.outbound_tls import outbound_tls_verify

from app.config import settings
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.canonical import canonical_json
from shared.security.discovery_peer_view import aggregate_discovery_peer_view
from shared.security.discovery_source_set import load_discovery_source_credentials
from shared.security.peer_selection import PeerSelectionPolicy, select_peer_set
from shared.security.peer_selection_state import (
    load_or_create_selection_seed,
    load_peer_selection_state,
    save_peer_selection_state,
)
from shared.security.node_identity_credentials import node_identity_registration_fields
from shared.security.transport_certificate import validate_transport_certificate


logger = logging.getLogger(__name__)
GOSSIP_PATH = "/registry/node-advertisements/gossip"
MAX_PAGES_PER_DISCOVERY = 10
_relay_urls: tuple[str, ...] = ()
_reserve_urls: tuple[str, ...] = ()
_capability_urls: dict[str, tuple[str, ...]] = {}
_last_error: str | None = None
_selection_epoch: int | None = None
_valid_until: datetime | None = None


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _validated_discovery_origin(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("peer Discovery URL must be an http(s) origin without credentials")
    return value.rstrip("/")


def _relay_base_url(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme not in {"https", "wss"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("signed Relay endpoint must be https or wss without credentials")
    scheme = "https" if parsed.scheme == "wss" else parsed.scheme
    path = parsed.path.rstrip("/")
    if path.endswith("/relay/ws"):
        path = path[: -len("/relay/ws")]
    return urlunsplit((scheme, parsed.netloc, path, "", "")).rstrip("/")


def _state_is_current(now: datetime | None = None) -> bool:
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    return _valid_until is not None and current <= _valid_until


def signed_relay_urls(*, now: datetime | None = None) -> list[str]:
    return list(_relay_urls) if _state_is_current(now) else []


def signed_reserve_urls(*, now: datetime | None = None) -> list[str]:
    return list(_reserve_urls) if _state_is_current(now) else []


def signed_capability_urls(capability: str, *, now: datetime | None = None) -> list[str]:
    if capability not in {"storage", "media", "turn", "gateway"}:
        raise ValueError("unsupported auxiliary capability")
    return list(_capability_urls.get(capability, ())) if _state_is_current(now) else []


def peer_runtime_status() -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    return {
        "mode": settings.signed_peer_selection_mode,
        "relay_count": len(_relay_urls),
        "reserve_count": len(_reserve_urls),
        "auxiliary_counts": {
            capability: len(urls) for capability, urls in _capability_urls.items()
        },
        "selection_epoch": _selection_epoch,
        "state_valid": _state_is_current(now),
        "valid_until": _iso(_valid_until) if _valid_until is not None else None,
        "last_error": _last_error,
    }


def _load_persisted(now: datetime) -> None:
    global _relay_urls, _reserve_urls, _selection_epoch, _valid_until, _last_error
    _relay_urls = ()
    _reserve_urls = ()
    _selection_epoch = None
    _valid_until = None
    try:
        state = load_peer_selection_state(settings.peer_selection_state_path, now=now)
    except ValueError as exc:
        _last_error = str(exc)
        return
    if state is None:
        return
    _relay_urls = tuple(
        entry["endpoint"]
        for bucket in ("guards", "rotating")
        for entry in state[bucket]
    )
    _reserve_urls = tuple(entry["endpoint"] for entry in state["reserves"])
    _selection_epoch = state["selection_epoch"]
    _valid_until = datetime.fromisoformat(
        state["valid_until"][:-1] + "+00:00"
        if state["valid_until"].endswith("Z")
        else state["valid_until"]
    ).astimezone(timezone.utc)
    _last_error = None


async def _fetch_observations(client: httpx.AsyncClient) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    for origin_value in settings.peer_discovery_urls:
        origin = _validated_discovery_origin(origin_value)
        try:
            cursor = ""
            for _page in range(MAX_PAGES_PER_DISCOVERY):
                response = await client.get(
                    f"{origin}{GOSSIP_PATH}",
                    params={"after_node_id": cursor, "limit": 100},
                )
                response.raise_for_status()
                payload = response.json()
                page = payload.get("observations")
                if not isinstance(page, list) or len(page) > 100:
                    raise ValueError("invalid Discovery observation response")
                if not page:
                    break
                observations.extend(page)
                subjects = []
                for item in page:
                    advertisement = item.get("advertisement") if isinstance(item, dict) else None
                    subject = advertisement.get("node_id") if isinstance(advertisement, dict) else None
                    if not isinstance(subject, str):
                        raise ValueError("invalid Discovery observation subject")
                    subjects.append(subject)
                next_cursor = max(subjects)
                if len(page) < 100:
                    break
                if next_cursor <= cursor:
                    raise ValueError("Discovery observation cursor did not advance")
                cursor = next_cursor
        except Exception as exc:
            logger.warning("Peer Discovery %s failed: %s", origin, exc)
    return observations


def _state_peer(candidate) -> dict[str, str]:
    return {
        "node_id": candidate.node_id,
        "endpoint": _relay_base_url(candidate.endpoint),
        "diversity_group": candidate.diversity_group,
    }


def _candidate_deadline(candidate: dict[str, Any]) -> datetime:
    values = (
        candidate["advertisement_expires_at"],
        candidate["observation_valid_until"],
        candidate["operational_valid_until"],
        candidate["capability_valid_until"],
        candidate["transport_certificate"]["valid_until"],
    )
    deadlines = []
    for value in values:
        if not isinstance(value, str):
            raise ValueError("peer validity deadline must be a string")
        parsed = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError("peer validity deadline must include timezone")
        deadlines.append(parsed.astimezone(timezone.utc))
    return min(deadlines)


async def refresh_signed_peer_set(
    *,
    client: httpx.AsyncClient | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    global _relay_urls, _reserve_urls, _capability_urls
    global _last_error, _selection_epoch, _valid_until
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    authority = load_capability_authority_state(settings.peer_authority_state_path)
    if authority is None:
        raise ValueError("peer authority state is unavailable")
    sources = load_discovery_source_credentials(
        settings.peer_discovery_source_set_path,
        authority_state=authority,
        now=current_time,
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(timeout=5.0, follow_redirects=False, trust_env=False, verify=outbound_tls_verify())
    try:
        observations = await _fetch_observations(client)
    finally:
        if own_client:
            await client.aclose()
    view = aggregate_discovery_peer_view(
        [
            {
                "advertisement": item["advertisement"],
                "capability_certificate": item["capability_certificate"],
                "observation": item["observation"],
            }
            for item in observations
            if isinstance(item, dict)
            and all(
                key in item
                for key in ("advertisement", "capability_certificate", "observation")
            )
        ],
        now=current_time,
        authority_state=authority,
        trusted_discovery_sources=sources,
        minimum_sources=2,
    )
    enriched_candidates: list[dict[str, Any]] = []
    for candidate in view.candidates:
        matching = [
            item
            for item in observations
            if isinstance(item, dict)
            and isinstance(item.get("advertisement"), dict)
            and item["advertisement"].get("node_id") == candidate["node_id"]
            and item["advertisement"].get("epoch")
            == candidate["advertisement_epoch"]
            and isinstance(item.get("transport_certificate"), dict)
            and isinstance(item.get("observation"), dict)
        ]
        variants: dict[str, list[dict[str, Any]]] = {}
        for item in matching:
            encoded = canonical_json(dict(item["transport_certificate"]))
            variants.setdefault(encoded, []).append(item)
        if len(variants) != 1:
            continue
        matching_variant = next(iter(variants.values()))
        if (
            len(
                {
                    item["observation"].get("source_node_id")
                    for item in matching_variant
                }
            )
            < 2
        ):
            continue
        certificate = matching_variant[0]["transport_certificate"]
        validation = validate_transport_certificate(
            certificate,
            now=current_time,
            expected_node_id=candidate["node_id"],
        )
        if not validation.valid:
            continue
        enriched = dict(candidate)
        enriched["transport_certificate"] = certificate
        enriched_candidates.append(enriched)
    try:
        previous = load_peer_selection_state(
            settings.peer_selection_state_path,
            now=current_time,
        )
    except ValueError:
        previous = None
    previous_guards = [entry["node_id"] for entry in previous["guards"]] if previous else []
    epoch = int(current_time.timestamp()) // settings.peer_selection_rotation_seconds
    local_identity = node_identity_registration_fields(
        root_key_path=settings.root_key_path,
        operational_key_path=settings.signing_key_path,
        certificate_path=settings.operational_certificate_path,
    )["operational_certificate"]["node_id"]
    selection = select_peer_set(
        enriched_candidates,
        self_node_id=local_identity,
        capability="relay",
        epoch=epoch,
        selection_secret=load_or_create_selection_seed(settings.peer_selection_seed_path),
        previous_guard_ids=previous_guards,
        policy=PeerSelectionPolicy(),
    )
    signed_deadline = min(
        (_candidate_deadline(candidate) for candidate in enriched_candidates),
        default=current_time + timedelta(minutes=5),
    )
    valid_until = min(current_time + timedelta(minutes=5), signed_deadline)
    if valid_until <= current_time:
        raise ValueError("signed peer view has no remaining validity")
    state = {
        "state_version": 1,
        "selection_epoch": epoch,
        "guards": [_state_peer(candidate) for candidate in selection.guards],
        "rotating": [_state_peer(candidate) for candidate in selection.rotating],
        "reserves": [_state_peer(candidate) for candidate in selection.reserves],
        "updated_at": _iso(current_time),
        "valid_until": _iso(valid_until),
    }
    save_peer_selection_state(settings.peer_selection_state_path, state, now=current_time)
    _relay_urls = tuple(
        entry["endpoint"]
        for bucket in ("guards", "rotating")
        for entry in state[bucket]
    )
    _reserve_urls = tuple(entry["endpoint"] for entry in state["reserves"])
    _capability_urls = {
        capability: tuple(
            sorted(
                {
                    _relay_base_url(candidate["endpoint"])
                    for candidate in enriched_candidates
                    if capability in candidate["capabilities"]
                    and candidate["node_id"] != local_identity
                }
            )
        )
        for capability in ("storage", "media", "turn", "gateway")
    }
    _selection_epoch = epoch
    _valid_until = valid_until
    _last_error = None
    return {
        "relay_count": len(_relay_urls),
        "reserve_count": len(_reserve_urls),
        "eligible_count": selection.eligible_count,
        "degraded": selection.degraded,
        "conflicts": list(view.conflicts),
        "rejected_count": view.rejected_count,
    }


async def _refresh_loop() -> None:
    global _last_error
    while True:
        try:
            await refresh_signed_peer_set()
        except Exception as exc:
            _last_error = str(exc)
            logger.warning("Signed peer refresh failed: %s", exc)
        await asyncio.sleep(settings.peer_selection_refresh_seconds)


def start_peer_runtime() -> asyncio.Task | None:
    if settings.signed_peer_selection_mode == "off":
        return None
    now = datetime.now(timezone.utc)
    _load_persisted(now)
    if len(settings.peer_discovery_urls) < 2:
        if settings.signed_peer_selection_mode == "enforce":
            raise RuntimeError("enforce signed peer selection requires at least two Discovery URLs")
        logger.warning("Signed peer selection has fewer than two Discovery URLs")
    for origin in settings.peer_discovery_urls:
        _validated_discovery_origin(origin)
    return asyncio.create_task(_refresh_loop())
