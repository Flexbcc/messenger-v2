"""Bounded pull replication of assignment-bound signed TrustObservations."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.config import (
    CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED,
    CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS,
    CHALLENGE_ASSIGNMENT_GOSSIP_PEERS,
    CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS,
)
from app.trust_observation_store import (
    latest_observation_event_sequence,
    list_observation_events_after_sequence,
    publish_observation,
)
from shared.security.trust_evidence import trust_observation_hash


GOSSIP_PATH = "/registry/trust-observations/gossip"
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
            "TrustObservation gossip peer must be an http(s) origin without credentials"
        )
    return value.rstrip("/")


def build_observation_gossip(
    *, after_sequence: int = 0, limit: int = 100
) -> dict[str, Any]:
    return {
        "observations": list_observation_events_after_sequence(
            after_sequence=after_sequence,
            limit=limit,
        ),
        "head_sequence": latest_observation_event_sequence(),
    }


def ingest_observation_gossip(item: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "sequence",
        "assignment_id",
        "observation_hash",
        "observation",
        "operational_certificate",
    }:
        raise HTTPException(status_code=400, detail="invalid TrustObservation gossip item")
    sequence = item.get("sequence")
    assignment_id = item.get("assignment_id")
    observation = item.get("observation")
    certificate = item.get("operational_certificate")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 1
        or not isinstance(assignment_id, str)
        or not assignment_id
        or not isinstance(observation, Mapping)
        or not isinstance(certificate, Mapping)
    ):
        raise HTTPException(status_code=400, detail="invalid TrustObservation gossip item")
    try:
        digest = trust_observation_hash(observation)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid TrustObservation gossip object") from exc
    if item.get("observation_hash") != digest:
        raise HTTPException(status_code=400, detail="TrustObservation gossip hash mismatch")
    observation_id, accepted = publish_observation(
        observation,
        authorization=None,
        assignment_id=assignment_id,
        observer_certificate=certificate,
        historical_event=True,
    )
    return {
        "sequence": sequence,
        "assignment_id": assignment_id,
        "observation_id": observation_id,
        "observation_hash": digest,
        "accepted": accepted,
    }


async def poll_observation_peers_once(
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
            cursor = _peer_cursors.get(peer, 0)
            try:
                for _ in range(MAX_PAGES_PER_PEER):
                    response = await client.get(
                        f"{peer}{GOSSIP_PATH}",
                        params={"after_sequence": cursor, "limit": 100},
                    )
                    response.raise_for_status()
                    payload = response.json()
                    items = payload.get("observations")
                    head = payload.get("head_sequence")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < 0
                    ):
                        raise ValueError("invalid TrustObservation gossip response")
                    if head < cursor:
                        cursor = 0
                        continue
                    for item in items:
                        result = ingest_observation_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        cursor = max(cursor, result["sequence"])
                    _peer_cursors[peer] = cursor
                    if not items or cursor >= head:
                        break
                else:
                    raise ValueError("TrustObservation gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("TrustObservation gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_observation_peers_once()
        except Exception as exc:
            logger.warning("TrustObservation gossip cycle failed: %s", exc)
        await asyncio.sleep(CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS)


def start_trust_observation_gossip() -> asyncio.Task | None:
    if not CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED or not CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        return None
    for peer in CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
