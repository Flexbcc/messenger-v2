"""Home-side resolver for endpoint-signed RouteDescriptor views."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlsplit

import httpx

from app.config import settings
from shared.security.route_runtime import RouteResolution, resolve_route_view


logger = logging.getLogger(__name__)
_last_error: str | None = None
_last_resolution_at: datetime | None = None
_resolved_users = 0


def _origin(value: str) -> str:
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
        raise ValueError("route Discovery URL must be an http(s) origin without credentials")
    return value.rstrip("/")


async def _fetch_source(
    client: httpx.AsyncClient, origin: str, user_id: str
) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
    bootstrap_response, route_response = await asyncio.gather(
        client.get(f"{origin}/registry/bootstrap-records/{user_id}"),
        client.get(f"{origin}/registry/route-descriptors/{user_id}"),
    )
    bootstrap_response.raise_for_status()
    route_response.raise_for_status()
    bootstrap_payload = bootstrap_response.json()
    route_payload = route_response.json()
    bootstrap = bootstrap_payload.get("record")
    descriptors = route_payload.get("descriptors")
    if not isinstance(bootstrap, dict) or not isinstance(descriptors, list) or len(descriptors) > 3:
        raise ValueError("invalid route Discovery response")
    if any(not isinstance(descriptor, dict) for descriptor in descriptors):
        raise ValueError("invalid RouteDescriptor list")
    return origin, bootstrap, descriptors


async def resolve_user_route(user_id: str) -> RouteResolution:
    """Resolve through independent Discovery sources and validate locally."""
    global _last_error, _last_resolution_at, _resolved_users
    origins = tuple(_origin(value) for value in settings.route_discovery_urls)
    if len(origins) < settings.route_minimum_discovery_sources:
        raise ValueError("insufficient configured Discovery sources for route quorum")
    async with httpx.AsyncClient(
        timeout=5.0, follow_redirects=False, trust_env=False
    ) as client:
        results = await asyncio.gather(
            *(_fetch_source(client, origin, user_id) for origin in origins),
            return_exceptions=True,
        )
    views = []
    for origin, result in zip(origins, results):
        if isinstance(result, Exception):
            logger.warning("Route Discovery %s failed for %s: %s", origin, user_id, result)
            continue
        views.append(result)
    try:
        resolution = resolve_route_view(
            user_id=user_id,
            source_views=views,
            state_path=settings.route_runtime_state_path,
            now=datetime.now(timezone.utc),
            minimum_sources=settings.route_minimum_discovery_sources,
        )
    except Exception as exc:
        _last_error = str(exc)
        raise
    _last_error = None
    _last_resolution_at = datetime.now(timezone.utc)
    _resolved_users += 1
    return resolution


def route_runtime_status() -> dict[str, Any]:
    return {
        "mode": settings.route_resolution_mode,
        "discovery_sources": len(settings.route_discovery_urls),
        "minimum_sources": settings.route_minimum_discovery_sources,
        "resolved_users": _resolved_users,
        "last_resolution_at": (
            _last_resolution_at.isoformat().replace("+00:00", "Z")
            if _last_resolution_at is not None
            else None
        ),
        "last_error": _last_error,
    }


def validate_route_runtime_configuration() -> None:
    if settings.route_resolution_mode == "off":
        return
    origins = tuple(_origin(value) for value in settings.route_discovery_urls)
    if len(origins) < settings.route_minimum_discovery_sources:
        message = "route resolution requires enough independent Discovery URLs"
        if settings.route_resolution_mode == "enforce":
            raise RuntimeError(message)
        logger.warning(message)
