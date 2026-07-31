"""Connectivity checks for Operator Admin setup wizard."""
from __future__ import annotations

import os
import time
from typing import Any

import httpx

INTERNAL_PROBE_URLS = {
    "discovery": os.environ.get("DISCOVERY_NODE_URL", "http://discovery-node:8003"),
    "home": os.environ.get("HOME_NODE_URL", "http://home-node:8001"),
    "storage": os.environ.get("STORAGE_NODE_URL", "http://storage-node:8002"),
    "media": os.environ.get("MEDIA_NODE_URL", "http://media-node:8004"),
    "relay": os.environ.get("RELAY_NODE_URL", "http://relay-node:8005"),
}


def internal_probe_url(role: str, configured: str = "") -> str:
    """Admin runs inside Docker — probe sibling services by compose DNS, not localhost."""
    internal = INTERNAL_PROBE_URLS.get(role, "").strip()
    if internal:
        return internal
    return configured.strip()


async def probe_health(url: str, *, timeout: float = 4.0) -> dict[str, Any]:
    """Ping a node's /health and return structured result."""
    base = url.rstrip("/")
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(f"{base}/health")
            ms = round((time.perf_counter() - started) * 1000)
            if resp.status_code >= 400:
                return {
                    "ok": False,
                    "url": base,
                    "latency_ms": ms,
                    "error": f"HTTP {resp.status_code}",
                }
            data = resp.json()
            return {
                "ok": True,
                "url": base,
                "latency_ms": ms,
                "node_role": data.get("node_role"),
                "node_id": data.get("node_id"),
                "status": data.get("status", "ok"),
                "load": data.get("load"),
            }
    except httpx.TimeoutException:
        return {"ok": False, "url": base, "error": "Таймаут — нода не ответила"}
    except httpx.RequestError as exc:
        return {"ok": False, "url": base, "error": str(exc)}


async def probe_discovery(url: str, *, timeout: float = 6.0) -> dict[str, Any]:
    """Check Discovery registry is reachable."""
    base = url.rstrip("/")
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            health = await client.get(f"{base}/health")
            ms = round((time.perf_counter() - started) * 1000)
            if health.status_code >= 400:
                return {"ok": False, "url": base, "latency_ms": ms, "error": f"HTTP {health.status_code}"}
            reg_started = time.perf_counter()
            reg = await client.get(f"{base}/registry/nodes")
            reg_ms = round((time.perf_counter() - reg_started) * 1000)
            if reg.status_code >= 400:
                return {
                    "ok": False,
                    "url": base,
                    "latency_ms": ms,
                    "error": f"Registry HTTP {reg.status_code}",
                }
            nodes = reg.json().get("nodes") or []
            return {
                "ok": True,
                "url": base,
                "latency_ms": ms,
                "registry_latency_ms": reg_ms,
                "registered_nodes": len(nodes),
                "node_role": "discovery",
            }
    except httpx.TimeoutException:
        return {"ok": False, "url": base, "error": "Таймаут — Discovery не ответил"}
    except httpx.RequestError as exc:
        return {"ok": False, "url": base, "error": str(exc)}


async def probe_media_admin(media_url: str, path: str = "/health", *, timeout: float = 5.0) -> dict[str, Any]:
    base = media_url.rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(f"{base}{path}")
            if resp.status_code >= 400:
                return {"ok": False, "url": base, "error": f"HTTP {resp.status_code}"}
            return {"ok": True, "url": base, "data": resp.json()}
    except Exception as exc:
        return {"ok": False, "url": base, "error": str(exc)}
