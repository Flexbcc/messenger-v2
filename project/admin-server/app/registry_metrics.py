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
        "runtime": None,
        "load": None,
    }
    if not probe:
        out["error"] = "no_url"
        return out

    health = await probe_health(probe)
    out["reachable"] = bool(health.get("ok"))
    out["latency_ms"] = health.get("latency_ms")
    out["load"] = health.get("load")
    out["runtime"] = health.get("runtime")

    if role == "home" and out["reachable"]:
        async with httpx.AsyncClient(
            timeout=6.0, follow_redirects=False, trust_env=False
        ) as client:
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


async def collect_transport_summary(nodes: list[dict[str, Any]]) -> dict[str, Any]:
    """Probe all Home nodes from Admin's network and aggregate safe counters."""
    home_nodes = [
        node for node in nodes
        if "home" in (node.get("capabilities") or [])
    ]
    snapshots = await asyncio.gather(
        *(metrics_for_node(node) for node in home_nodes),
        return_exceptions=True,
    )
    counter_names = (
        "direct_ok", "relay_ok", "buffer_ok", "failed",
        "home_online_accepted", "home_mailbox_accepted", "device_acked",
        "delivery_completed", "mailbox_replicas_purged",
    )
    totals = {name: 0 for name in counter_names}
    sources: list[dict[str, Any]] = []
    for node, snapshot in zip(home_nodes, snapshots):
        if isinstance(snapshot, BaseException):
            sources.append({
                "node_id": node.get("node_id"),
                "reachable": False,
                "error": type(snapshot).__name__,
            })
            continue
        load = snapshot.get("load") if isinstance(snapshot, dict) else None
        federation = load.get("federation") if isinstance(load, dict) else None
        policy = load.get("transport_policy") if isinstance(load, dict) else None
        transport_runtime = load.get("transport_runtime") if isinstance(load, dict) else None
        delivery_timing = load.get("delivery_timing") if isinstance(load, dict) else None
        runtime = snapshot.get("runtime") if isinstance(snapshot, dict) else None
        registration = runtime.get("registration") if isinstance(runtime, dict) else None
        if isinstance(federation, dict):
            for name in counter_names:
                value = federation.get(name)
                if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                    totals[name] += value
        sources.append({
            "node_id": node.get("node_id"),
            "reachable": bool(snapshot.get("reachable")),
            "latency_ms": snapshot.get("latency_ms"),
            "transport_policy": policy if isinstance(policy, dict) else None,
            "transport_runtime": (
                transport_runtime if isinstance(transport_runtime, dict) else None
            ),
            "delivery_timing": (
                delivery_timing if isinstance(delivery_timing, dict) else None
            ),
            "registration": registration if isinstance(registration, dict) else None,
        })
    return {
        "totals": totals,
        "home_nodes": len(home_nodes),
        "reachable_home_nodes": sum(1 for source in sources if source["reachable"]),
        "sources": sources,
    }
