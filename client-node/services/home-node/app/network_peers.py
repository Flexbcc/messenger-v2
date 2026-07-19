"""Anonymized network catalog for the owner-facing Home Node panel.

Never exposes node_url, IP, or raw node_id to the browser — only role + state.
Server-side pings remain internal.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

ROLE_LABELS = {
    "home": "Home",
    "relay": "Relay",
    "storage": "Storage",
    "media": "Media",
    "discovery": "Discovery",
    "witness": "Witness",
    "gateway": "Gateway",
    "turn": "TURN",
}

STATUS_RU = {
    "online": "Онлайн",
    "offline": "Оффлайн",
    "normal": "Норма",
    "busy": "Нагрузка",
    "overloaded": "Перегруз",
    "critical": "Критично",
}


def _opaque_ref(node_id: str) -> str:
    raw = f"{settings.node_id}|{node_id}".encode()
    return hashlib.sha256(raw).hexdigest()[:10]


def _primary_role(capabilities: list | None, fallback: str | None = None) -> str:
    if capabilities:
        return str(capabilities[0]).lower()
    if fallback:
        return str(fallback).lower()
    return "node"


def _runtime_hint_from_load(role: str, load: dict | None) -> str | None:
    if not load:
        return None
    if role == "home":
        ws = load.get("active_ws_connections") or 0
        if ws > 80:
            return "overloaded"
        if ws > 40:
            return "busy"
        return "normal"
    if role == "relay":
        n = load.get("forwarded_count") or 0
        if n > 10_000:
            return "busy"
        return "normal"
    if role == "storage":
        n = load.get("buffered_count") or 0
        if n > 500:
            return "busy"
        return "normal"
    return "normal"


async def _ping_health(node_url: str, timeout: float = 2.5) -> dict[str, Any]:
    url = f"{node_url.rstrip('/')}/health"
    t0 = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(url)
            ms = round((time.perf_counter() - t0) * 1000)
            if resp.status_code >= 400:
                return {"reachable": False, "load": None, "node_role": None, "latency_ms": ms}
            data = resp.json()
            return {
                "reachable": True,
                "load": data.get("load"),
                "node_role": data.get("node_role"),
                "latency_ms": ms,
            }
    except Exception:
        return {"reachable": False, "load": None, "node_role": None, "latency_ms": None}


async def _empty_ping() -> dict[str, Any]:
    return {"reachable": False, "load": None, "node_role": None}


async def fetch_registry_nodes() -> list[dict]:
    if not settings.discovery_url:
        return []
    url = f"{settings.discovery_url.rstrip('/')}/registry/nodes"
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            resp = await client.get(url, params={"include_untrusted": "true"})
            resp.raise_for_status()
            return list(resp.json().get("nodes") or [])
    except Exception as exc:
        logger.warning("Cannot fetch registry for anonymous peers: %s", exc)
        return []


async def build_anonymous_peers(*, probe: bool = True) -> dict[str, Any]:
    """Return privacy-safe peer catalog for the user panel."""
    nodes = await fetch_registry_nodes()

    if probe and nodes:
        tasks = [
            _ping_health(n["node_url"]) if n.get("node_url") else _empty_ping()
            for n in nodes
        ]
        pings = list(await asyncio.gather(*tasks))
    else:
        pings = [{} for _ in nodes]

    role_counters: dict[str, int] = {}
    peers: list[dict] = []

    for raw, ping in zip(nodes, pings):
        node_id = raw.get("node_id") or ""
        caps = raw.get("capabilities") or []
        role = _primary_role(caps)
        is_self = node_id == settings.node_id
        reach = (raw.get("reachability") or raw.get("status") or "offline").lower()

        load = None
        if probe:
            if ping.get("reachable"):
                reach = "online"
                load = ping.get("load")
                if ping.get("node_role"):
                    role = _primary_role(caps, ping["node_role"])
            elif reach == "online":
                reach = "offline"

        hint = _runtime_hint_from_load(role, load) if reach == "online" else None
        display_status = hint or reach

        role_counters[role] = role_counters.get(role, 0) + 1
        idx = role_counters[role]
        role_label = ROLE_LABELS.get(role, role.title())
        display_name = role_label if idx == 1 and not is_self else f"{role_label} · {idx}"
        if is_self:
            display_name = "Моя нода"

        peers.append(
            {
                "peer_ref": _opaque_ref(node_id) if node_id else f"unknown-{idx}",
                "role": role,
                "role_label": role_label,
                "display_name": display_name,
                "status": display_status,
                "status_label": STATUS_RU.get(display_status, display_status),
                "online": reach == "online",
                "is_self": is_self,
                "latency_ms": ping.get("latency_ms") if probe and ping.get("reachable") else None,
            }
        )

    peers.sort(key=lambda p: (not p["is_self"], p["role"], p["display_name"]))
    by_role: dict[str, int] = {}
    online = 0
    for p in peers:
        by_role[p["role"]] = by_role.get(p["role"], 0) + 1
        if p["online"]:
            online += 1

    return {
        "peers": peers,
        "summary": {
            "total": len(peers),
            "online": online,
            "offline": len(peers) - online,
            "by_role": by_role,
        },
        "privacy": "role_and_status_only",
    }
