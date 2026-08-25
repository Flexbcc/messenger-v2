"""Authenticated pull-gossip for validated AuthorityCheckpoint chains."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlsplit

import httpx
from shared.security.outbound_tls import outbound_tls_verify
from fastapi import HTTPException

from app.authority_checkpoint_store import (
    AuthorityCheckpointConflict,
    ingest_authority_gossip,
    latest_checkpoint,
    list_checkpoints,
)
from app.config import (
    AUTHORITY_GOSSIP_ENABLED,
    AUTHORITY_GOSSIP_INTERVAL_SECONDS,
    AUTHORITY_GOSSIP_PEERS,
    AUTHORITY_GOSSIP_TIMEOUT_SECONDS,
    DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.network_guard import get_network_view_guard
from app.node_identity import discovery_node_identity
from shared.security.authority_gossip import issue_authority_announcement
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.keys import load_or_create_signing_key


logger = logging.getLogger(__name__)
GOSSIP_PATH = "/registry/authority-checkpoints/gossip"


def _validated_peer_url(value: str) -> str:
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
        raise ValueError("authority gossip peer must be an http(s) origin without credentials")
    return value.rstrip("/")


def build_gossip_items(
    *,
    after_epoch: int,
    limit: int,
    now: datetime | None = None,
) -> list[dict[str, Any]]:
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    identity = discovery_node_identity()["operational_certificate"]
    signing_key = load_or_create_signing_key(DISCOVERY_NODE_OPERATIONAL_KEY_PATH)
    items = []
    for stored in list_checkpoints(after_epoch=after_epoch, limit=limit):
        items.append(
            _signed_gossip_item(
                stored,
                source_node_id=identity["node_id"],
                signing_key=signing_key,
                now=current_time,
            )
        )
    return items


def _signed_gossip_item(
    stored: dict[str, Any],
    *,
    source_node_id: str,
    signing_key,
    now: datetime,
) -> dict[str, Any]:
    checkpoint = stored["checkpoint"]
    announcement = issue_authority_announcement(
        source_node_id=source_node_id,
        authority_epoch=checkpoint["authority_epoch"],
        checkpoint_hash=stored["checkpoint_hash"],
        announced_at=now,
        expires_at=now + timedelta(minutes=5),
        source_signing_key=signing_key,
    )
    return {**stored, "announcement": announcement}


def build_gossip_head(*, now: datetime | None = None) -> dict[str, Any] | None:
    stored = latest_checkpoint()
    if stored is None:
        return None
    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    identity = discovery_node_identity()["operational_certificate"]
    signing_key = load_or_create_signing_key(DISCOVERY_NODE_OPERATIONAL_KEY_PATH)
    return _signed_gossip_item(
        stored,
        source_node_id=identity["node_id"],
        signing_key=signing_key,
        now=current_time,
    )


def ingest_gossip_item(
    item: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    if not isinstance(item, dict) or not isinstance(item.get("checkpoint"), dict):
        raise HTTPException(status_code=400, detail="invalid authority gossip item")
    decision = get_network_view_guard().decision()
    if not decision.governance_allowed:
        raise HTTPException(
            status_code=503,
            detail=f"control plane is frozen: {decision.frozen_reason}",
        )
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    if bootstrap is None:
        raise HTTPException(status_code=503, detail="bootstrap authority state is unavailable")
    checkpoint = item["checkpoint"]
    try:
        digest, checkpoint_accepted, announcement_accepted, source_node_id = (
            ingest_authority_gossip(
                checkpoint,
                item.get("announcement"),
                bootstrap_state=bootstrap,
                now=now,
            )
        )
    except AuthorityCheckpointConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum AuthorityCheckpoint gossip detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    get_network_view_guard().observe_validated_checkpoint(
        source_node_id=source_node_id,
        authority_epoch=checkpoint["authority_epoch"],
        checkpoint_hash=digest,
        previous_hash=checkpoint["previous_hash"],
    )
    return {
        "source_node_id": source_node_id,
        "authority_epoch": checkpoint["authority_epoch"],
        "checkpoint_hash": digest,
        "checkpoint_accepted": checkpoint_accepted,
        "announcement_accepted": announcement_accepted,
    }


async def poll_authority_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured_peers = tuple(_validated_peer_url(peer) for peer in (peers or AUTHORITY_GOSSIP_PEERS))
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    if bootstrap is None:
        raise RuntimeError("bootstrap authority state is unavailable")
    latest = latest_checkpoint()
    initial_after_epoch = (
        latest["checkpoint"]["authority_epoch"] if latest is not None else bootstrap.epoch
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(
            timeout=AUTHORITY_GOSSIP_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False, verify=outbound_tls_verify(),
        )
    fetched = accepted = failed = 0
    try:
        for peer in configured_peers:
            try:
                peer_after_epoch = initial_after_epoch
                response = await client.get(
                    f"{peer}{GOSSIP_PATH}",
                    params={"after_epoch": peer_after_epoch, "limit": 100},
                )
                response.raise_for_status()
                payload = response.json()
                items = payload.get("checkpoints")
                if not isinstance(items, list) or len(items) > 100:
                    raise ValueError("invalid authority gossip response")
                for item in items:
                    fetched += 1
                    result = ingest_gossip_item(item)
                    if result["checkpoint_accepted"]:
                        accepted += 1
                    peer_after_epoch = max(peer_after_epoch, result["authority_epoch"])
                head = payload.get("head")
                if head is not None:
                    if not isinstance(head, dict):
                        raise ValueError("invalid authority gossip head")
                    head_checkpoint = head.get("checkpoint")
                    head_epoch = (
                        head_checkpoint.get("authority_epoch")
                        if isinstance(head_checkpoint, dict)
                        else None
                    )
                    if (
                        isinstance(head_epoch, int)
                        and not isinstance(head_epoch, bool)
                        and head_epoch <= initial_after_epoch
                    ):
                        fetched += 1
                        ingest_gossip_item(head)
            except Exception as exc:
                failed += 1
                logger.warning("Authority gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_authority_peers_once()
        except Exception as exc:
            logger.warning("Authority gossip cycle failed: %s", exc)
        await asyncio.sleep(AUTHORITY_GOSSIP_INTERVAL_SECONDS)


def start_authority_gossip() -> asyncio.Task | None:
    if not AUTHORITY_GOSSIP_ENABLED or not AUTHORITY_GOSSIP_PEERS:
        return None
    for peer in AUTHORITY_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
