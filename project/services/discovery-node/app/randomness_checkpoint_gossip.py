"""Bounded pull replication of quorum-signed RandomnessCheckpoints."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.config import (
    CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED,
    CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS,
    CHALLENGE_ASSIGNMENT_GOSSIP_PEERS,
    CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.network_guard import get_network_view_guard, require_governance_available
from app.randomness_checkpoint_store import (
    RandomnessCheckpointConflict,
    latest_randomness_checkpoint,
    list_randomness_checkpoints,
    publish_randomness_checkpoint,
)
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.randomness_checkpoint import randomness_checkpoint_hash


GOSSIP_PATH = "/registry/randomness-checkpoints/gossip"
MAX_PAGES_PER_PEER = 100
logger = logging.getLogger(__name__)
_peer_cursors: dict[str, int] = {}


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
        raise ValueError(
            "RandomnessCheckpoint gossip peer must be an http(s) origin without credentials"
        )
    return value.rstrip("/")


def build_randomness_gossip(
    *, after_epoch: int = -1, limit: int = 100
) -> dict[str, Any]:
    checkpoints = list_randomness_checkpoints(
        after_epoch=after_epoch,
        limit=limit,
    )
    latest = latest_randomness_checkpoint()
    return {
        "checkpoints": checkpoints,
        "head_epoch": (
            latest["checkpoint"]["challenge_epoch"] if latest is not None else -1
        ),
    }


def ingest_randomness_gossip(item: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "checkpoint",
        "checkpoint_hash",
        "stored_at",
    }:
        raise HTTPException(status_code=400, detail="invalid RandomnessCheckpoint gossip item")
    checkpoint = item.get("checkpoint")
    if not isinstance(checkpoint, Mapping):
        raise HTTPException(status_code=400, detail="invalid RandomnessCheckpoint gossip item")
    try:
        expected_digest = randomness_checkpoint_hash(checkpoint)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid RandomnessCheckpoint gossip object") from exc
    if item.get("checkpoint_hash") != expected_digest:
        raise HTTPException(status_code=400, detail="RandomnessCheckpoint gossip hash mismatch")
    require_governance_available()
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    authority = load_authority_state_at_epoch(
        TRUST_AUTHORITY_STATE_PATH,
        checkpoint.get("authority_epoch"),
        bootstrap_state=bootstrap,
    )
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="authority state for RandomnessCheckpoint is unavailable",
        )
    try:
        digest, accepted = publish_randomness_checkpoint(
            checkpoint,
            authority_state=authority,
        )
    except RandomnessCheckpointConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum RandomnessCheckpoints detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    return {
        "challenge_epoch": checkpoint["challenge_epoch"],
        "checkpoint_hash": digest,
        "accepted": accepted,
    }


async def poll_randomness_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured = tuple(
        _validated_peer_url(peer)
        for peer in (peers or CHALLENGE_ASSIGNMENT_GOSSIP_PEERS)
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(
            timeout=CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False,
        )
    fetched = accepted = failed = 0
    try:
        for peer in configured:
            cursor = _peer_cursors.get(peer, -1)
            try:
                for _ in range(MAX_PAGES_PER_PEER):
                    response = await client.get(
                        f"{peer}{GOSSIP_PATH}",
                        params={"after_epoch": cursor, "limit": 100},
                    )
                    response.raise_for_status()
                    payload = response.json()
                    items = payload.get("checkpoints")
                    head = payload.get("head_epoch")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < -1
                    ):
                        raise ValueError("invalid RandomnessCheckpoint gossip response")
                    if head < cursor:
                        cursor = -1
                        continue
                    for item in items:
                        result = ingest_randomness_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        cursor = max(cursor, result["challenge_epoch"])
                    _peer_cursors[peer] = cursor
                    if not items or cursor >= head:
                        break
                else:
                    raise ValueError("RandomnessCheckpoint gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("RandomnessCheckpoint gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_randomness_peers_once()
        except Exception as exc:
            logger.warning("RandomnessCheckpoint gossip cycle failed: %s", exc)
        await asyncio.sleep(CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS)


def start_randomness_checkpoint_gossip() -> asyncio.Task | None:
    if not CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED or not CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        return None
    for peer in CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
