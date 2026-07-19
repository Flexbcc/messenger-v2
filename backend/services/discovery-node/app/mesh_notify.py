"""Discovery → peer nodes push when a trusted node joins or updates."""
from __future__ import annotations

import json
import logging
import os
import threading
from typing import Any, Iterable, Mapping

import httpx

from app.db import get_conn

logger = logging.getLogger(__name__)

MESH_NOTIFY_ENABLED = os.environ.get("MESH_NOTIFY_ENABLED", "true").lower() in (
    "1",
    "true",
    "yes",
    "on",
)
MESH_NOTIFY_SECRET = os.environ.get("MESH_NOTIFY_SECRET", "")
MESH_NOTIFY_TIMEOUT_SECONDS = float(os.environ.get("MESH_NOTIFY_TIMEOUT_SECONDS", "5"))


def _peer_payload(row: Mapping[str, Any]) -> dict:
    caps = row["capabilities"]
    if isinstance(caps, str):
        caps = json.loads(caps)
    return {
        "event": "peer_joined",
        "source": "discovery",
        "peer": {
            "node_id": row["node_id"],
            "node_url": row["node_url"],
            "capabilities": list(caps),
            "cluster_id": row["cluster_id"] or "default",
            "software_version": row["software_version"] or "unknown",
            "trust_status": row["trust_status"] or "trusted",
        },
    }


def _notify_peer_sync(peer_url: str, payload: dict) -> None:
    headers = {}
    if MESH_NOTIFY_SECRET:
        headers["X-Mesh-Notify-Secret"] = MESH_NOTIFY_SECRET
    url = f"{peer_url.rstrip('/')}/internal/mesh/peer-joined"
    try:
        with httpx.Client(timeout=MESH_NOTIFY_TIMEOUT_SECONDS) as client:
            resp = client.post(url, json=payload, headers=headers)
            resp.raise_for_status()
        logger.info("Mesh notify OK → %s for peer %s", peer_url, payload["peer"]["node_id"])
    except httpx.HTTPError as exc:
        logger.warning(
            "Mesh notify failed → %s for peer %s: %s",
            peer_url,
            payload["peer"]["node_id"],
            exc,
        )


def _notify_all_peers_sync(peer_rows: Iterable[Mapping[str, Any]], payload: dict) -> None:
    for row in peer_rows:
        peer_url = row["node_url"]
        if not peer_url:
            continue
        _notify_peer_sync(peer_url, payload)


def schedule_mesh_peer_notify(new_node_row: Mapping[str, Any], *, reason: str = "register") -> None:
    """
    Fire-and-forget: tell every other trusted node in the same cluster
    that `new_node_row` joined or changed materially.
    """
    if not MESH_NOTIFY_ENABLED:
        return
    if (new_node_row["trust_status"] or "") != "trusted":
        return

    cluster_id = new_node_row["cluster_id"] or "default"
    node_id = new_node_row["node_id"]
    payload = _peer_payload(new_node_row)

    with get_conn() as conn:
        peers = conn.execute(
            """
            SELECT node_id, node_url, capabilities, cluster_id, software_version, trust_status
            FROM node_capabilities
            WHERE trust_status = 'trusted' AND node_id != ? AND cluster_id = ?
            """,
            (node_id, cluster_id),
        ).fetchall()
        peer_list = [dict(r) for r in peers]

    logger.info(
        "Scheduling mesh notify (%s) for node_id=%s to %d peer(s) in cluster=%s",
        reason,
        node_id,
        len(peer_list),
        cluster_id,
    )

    def _run() -> None:
        _notify_all_peers_sync(peer_list, payload)

    threading.Thread(target=_run, daemon=True).start()


def should_notify_on_register(existing_row, payload, final_trust: str) -> bool:
    """Notify peers only on first trusted appearance or material change."""
    if final_trust != "trusted":
        return False
    if not existing_row:
        return True
    if (existing_row["trust_status"] or "") != "trusted":
        return True
    if existing_row["node_url"] != payload.node_url:
        return True
    try:
        old_caps = json.loads(existing_row["capabilities"])
    except (TypeError, json.JSONDecodeError):
        old_caps = []
    if old_caps != payload.capabilities:
        return True
    return False
