"""Fetch CPU/RAM/load from registered nodes for Operator Admin."""
from __future__ import annotations

import asyncio
import os
from typing import Any
from urllib.parse import urlparse

import httpx

from app.checks import internal_probe_url, probe_health

# Dev: map public localhost URLs to Docker DNS (admin container probes).
_LOCAL_HOME_PROBE: dict[str, str] = {
    "http://localhost:8001": os.environ.get("PROBE_HOME_DEFAULT", "http://project-home-node-1:8001"),
    "http://localhost:9205": os.environ.get("PROBE_HOME_OPERATOR", "http://main-node-home-node-1:8001"),
    "http://localhost:18011": os.environ.get("PROBE_HOME_CLIENT", "http://client-node-home-node-1:8001"),
}


def probe_url_for_node(node_url: str, node_id: str = "") -> str:
    base = (node_url or "").strip().rstrip("/")
    if not base:
        return ""
    if base in _LOCAL_HOME_PROBE:
        return _LOCAL_HOME_PROBE[base]
    parsed = urlparse(base)
    host = (parsed.hostname or "").lower()
    if host in ("localhost", "127.0.0.1") and parsed.port:
        return f"http://host.docker.internal:{parsed.port}"
    if host == "home-node":
        return internal_probe_url("home", base)
    if host == "storage-node":
        return internal_probe_url("storage", base)
    if host == "relay-node":
        return internal_probe_url("relay", base)
    if host == "media-node":
        return internal_probe_url("media", base)
    return base


async def _fetch_home_snapshot(client: httpx.AsyncClient, probe: str) -> dict[str, Any] | None:
    try:
        resp = await client.get(f"{probe.rstrip('/')}/monitor/snapshot")
        if resp.status_code >= 400:
            return None
        return resp.json()
    except httpx.HTTPError:
        return None


async def metrics_for_node(node: dict[str, Any]) -> dict[str, Any]:
    role = (node.get("capabilities") or ["node"])[0]
    node_url = node.get("node_url") or ""
    probe = probe_url_for_node(node_url, node.get("node_id", ""))
    out: dict[str, Any] = {
        "node_id": node.get("node_id"),
        "node_url": node_url,
        "probe_url": probe,
        "cluster_id": node.get("cluster_id"),
        "role": role,
        "trust_status": node.get("trust_status"),
        "status": node.get("status") or node.get("reachability"),
        "reachable": False,
        "latency_ms": None,
        "metrics": None,
        "health_score": None,
        "runtime_status": None,
        "load": None,
    }
    if not probe:
        out["error"] = "no_url"
        return out

    health = await probe_health(probe)
    out["reachable"] = bool(health.get("ok"))
    out["latency_ms"] = health.get("latency_ms")
    out["load"] = health.get("load")

    if role == "home" and out["reachable"]:
        async with httpx.AsyncClient(timeout=6.0) as client:
            snap = await _fetch_home_snapshot(client, probe)
        if snap:
            m = snap.get("metrics") or {}
            out["metrics"] = {
                "cpu_percent_est": m.get("cpu_percent_est"),
                "ram_used_bytes": m.get("ram_used_bytes"),
                "ram_total_bytes": m.get("ram_total_bytes"),
                "ram_percent": m.get("ram_percent"),
                "disk_used_bytes": m.get("disk_used_bytes"),
                "disk_total_bytes": m.get("disk_total_bytes"),
                "disk_percent": m.get("disk_percent"),
                "uptime_sec": m.get("uptime_sec"),
                "online_users": m.get("online_users"),
                "active_ws_connections": m.get("active_ws_connections"),
            }
            out["health_score"] = snap.get("health_score")
            out["runtime_status"] = snap.get("runtime_status")
    return out


def _node_score(node: dict[str, Any]) -> int:
    score = 0
    status = str(node.get("status") or node.get("reachability") or "offline").lower()
    if status == "online":
        score += 100
    node_id = str(node.get("node_id") or "")
    if node_id.endswith("-local") or "-operator-" in node_id or "-client-" in node_id:
        score += 15
    if "dockertest" in node_id or node_id.startswith("test-") or "-e2e" in node_id:
        score -= 40
    return score


def dedupe_registry_nodes(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    best: dict[str, dict[str, Any]] = {}
    for n in nodes:
        role = (n.get("capabilities") or ["node"])[0]
        cluster = n.get("cluster_id") or "default"
        key = f"{cluster}:{role}"
        prev = best.get(key)
        if not prev or _node_score(n) > _node_score(prev):
            best[key] = n
    return list(best.values())


async def collect_registry_metrics(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped = dedupe_registry_nodes(nodes)
    tasks = [metrics_for_node(n) for n in deduped]
    return list(await asyncio.gather(*tasks))
