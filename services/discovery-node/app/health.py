"""Active health-check for registered nodes (Node Monitor).

Passive heartbeat only tells us whether a node *reported in* recently. This
module additionally pings each node's real ``/health`` endpoint so Discovery can
distinguish:

  online       — heartbeat fresh AND /health responded ok
  unreachable  — heartbeat fresh BUT /health did not respond / errored
  offline      — heartbeat stale (no need to probe)

It complements, and does not replace, the heartbeat-based reachability in
``trust.reachability_for``. Controlled by DISCOVERY_HEALTHCHECK_* env
(see config.py). Disabled by default.
"""
import asyncio
import logging

import httpx

from app.config import (
    HEALTHCHECK_ENABLED,
    HEALTHCHECK_INTERVAL_SECONDS,
    HEALTHCHECK_TIMEOUT_SECONDS,
    REACHABILITY_OFFLINE,
    REACHABILITY_ONLINE,
    REACHABILITY_UNREACHABLE,
)
from app.db import get_conn
from app.trust import now_iso, reachability_for

logger = logging.getLogger(__name__)


def derive_health_status(heartbeat_reachability: str, ping_ok: bool) -> str:
    """Pure decision: combine passive heartbeat reachability with an active ping.

    - stale heartbeat  -> offline (don't bother trusting a ping)
    - fresh heartbeat + ping ok    -> online
    - fresh heartbeat + ping failed -> unreachable
    """
    if heartbeat_reachability == REACHABILITY_OFFLINE:
        return REACHABILITY_OFFLINE
    return REACHABILITY_ONLINE if ping_ok else REACHABILITY_UNREACHABLE


async def _ping(client: httpx.AsyncClient, node_url: str) -> bool:
    try:
        resp = await client.get(node_url.rstrip("/") + "/health", timeout=HEALTHCHECK_TIMEOUT_SECONDS)
        return resp.status_code == 200
    except Exception:
        return False


async def run_health_check_once(client: httpx.AsyncClient | None = None) -> list[dict]:
    """Probe every registered node once; persist health_status. Returns results."""
    with get_conn() as conn:
        rows = conn.execute("SELECT node_id, node_url, last_heartbeat FROM node_capabilities").fetchall()
        nodes = [(r["node_id"], r["node_url"], r["last_heartbeat"]) for r in rows]

    owns_client = client is None
    if owns_client:
        client = httpx.AsyncClient()
    results: list[dict] = []
    try:
        for node_id, node_url, last_heartbeat in nodes:
            heartbeat_reach = reachability_for(last_heartbeat)
            ping_ok = False
            if heartbeat_reach != REACHABILITY_OFFLINE:
                ping_ok = await _ping(client, node_url)
            health_status = derive_health_status(heartbeat_reach, ping_ok)
            checked_at = now_iso()
            with get_conn() as conn:
                conn.execute(
                    "UPDATE node_capabilities SET health_status = ?, last_health_check = ? WHERE node_id = ?",
                    (health_status, checked_at, node_id),
                )
                conn.commit()
            results.append(
                {
                    "node_id": node_id,
                    "reachability": heartbeat_reach,
                    "health_status": health_status,
                    "last_health_check": checked_at,
                }
            )
    finally:
        if owns_client:
            await client.aclose()
    return results


async def _health_loop() -> None:
    logger.info(
        "Active health-check enabled: interval=%ss timeout=%ss",
        HEALTHCHECK_INTERVAL_SECONDS,
        HEALTHCHECK_TIMEOUT_SECONDS,
    )
    async with httpx.AsyncClient() as client:
        while True:
            await asyncio.sleep(HEALTHCHECK_INTERVAL_SECONDS)
            try:
                await run_health_check_once(client)
            except Exception as e:  # pragma: no cover - defensive
                logger.warning("Health-check run failed: %s", e)


def start_health_monitor() -> None:
    """Start the background health-check loop if enabled (called on startup)."""
    if not HEALTHCHECK_ENABLED:
        return
    asyncio.create_task(_health_loop())
