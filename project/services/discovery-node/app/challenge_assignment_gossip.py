"""Bounded pull replication of quorum-signed ChallengeAssignments."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.authority_checkpoint_store import load_authority_state_at_epoch
from app.challenge_assignment_store import (
    AssignmentConflict,
    latest_assignment_sequence,
    list_assignments_after_sequence,
    publish_assignment,
)
from app.config import (
    CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED,
    CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS,
    CHALLENGE_ASSIGNMENT_GOSSIP_PEERS,
    CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS,
    TRUST_AUTHORITY_STATE_PATH,
)
from app.network_guard import get_network_view_guard, require_governance_available
from shared.security.capability_enrollment import load_capability_authority_state
from shared.security.challenge_assignment import challenge_assignment_hash


GOSSIP_PATH = "/registry/challenge-assignments/gossip"
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
            "ChallengeAssignment gossip peer must be an http(s) origin without credentials"
        )
    return value.rstrip("/")


def build_assignment_gossip(
    *, after_sequence: int = 0, limit: int = 100
) -> dict[str, Any]:
    records = list_assignments_after_sequence(
        after_sequence=after_sequence,
        limit=limit,
    )
    return {
        "assignments": [
            {
                **record,
                "assignment_hash": challenge_assignment_hash(record["assignment"]),
            }
            for record in records
        ],
        "head_sequence": latest_assignment_sequence(),
    }


def ingest_assignment_gossip(item: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "sequence",
        "assignment_hash",
        "assignment",
    }:
        raise HTTPException(status_code=400, detail="invalid ChallengeAssignment gossip item")
    sequence = item.get("sequence")
    assignment = item.get("assignment")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 1
        or not isinstance(assignment, Mapping)
    ):
        raise HTTPException(status_code=400, detail="invalid ChallengeAssignment gossip item")
    try:
        digest = challenge_assignment_hash(assignment)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid ChallengeAssignment gossip object") from exc
    if item.get("assignment_hash") != digest:
        raise HTTPException(status_code=400, detail="ChallengeAssignment gossip hash mismatch")
    require_governance_available()
    bootstrap = load_capability_authority_state(TRUST_AUTHORITY_STATE_PATH)
    try:
        authority = load_authority_state_at_epoch(
            TRUST_AUTHORITY_STATE_PATH,
            assignment.get("authority_epoch"),
            bootstrap_state=bootstrap,
        )
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"invalid Trust authority state: {exc}")
    if authority is None:
        raise HTTPException(
            status_code=503,
            detail="authority state for ChallengeAssignment epoch is unavailable",
        )
    try:
        assignment_id, accepted = publish_assignment(
            assignment,
            authority=authority,
            require_registered_participants=False,
        )
    except AssignmentConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting quorum ChallengeAssignments detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    return {
        "sequence": sequence,
        "assignment_id": assignment_id,
        "assignment_hash": digest,
        "accepted": accepted,
    }


async def poll_assignment_peers_once(
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
                    items = payload.get("assignments")
                    head = payload.get("head_sequence")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < 0
                    ):
                        raise ValueError("invalid ChallengeAssignment gossip response")
                    if head < cursor:
                        cursor = 0
                        continue
                    for item in items:
                        result = ingest_assignment_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        cursor = max(cursor, result["sequence"])
                    _peer_cursors[peer] = cursor
                    if not items or cursor >= head:
                        break
                else:
                    raise ValueError("ChallengeAssignment gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("ChallengeAssignment gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_assignment_peers_once()
        except Exception as exc:
            logger.warning("ChallengeAssignment gossip cycle failed: %s", exc)
        await asyncio.sleep(CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS)


def start_challenge_assignment_gossip() -> asyncio.Task | None:
    if not CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED or not CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        return None
    for peer in CHALLENGE_ASSIGNMENT_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
