"""Bounded pull replication of root-signed Operational Credential chains."""

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
    NODE_ADVERTISEMENT_GOSSIP_ENABLED,
    NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS,
    NODE_ADVERTISEMENT_GOSSIP_PEERS,
    NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS,
)
from app.network_guard import get_network_view_guard
from app.operational_credential_store import (
    OperationalCredentialConflict,
    OperationalCredentialRollback,
    list_operational_credential_states,
    operational_credential_latest_sequence,
    publish_operational_credential_state,
)
from shared.security.operational_credential_state import (
    operational_credential_state_hash,
)


GOSSIP_PATH = "/registry/operational-credential-states/gossip"
MAX_PAGES_PER_PEER = 100
logger = logging.getLogger(__name__)
_peer_cursors: dict[str, int] = {}


def _configured_peers() -> tuple[str, ...]:
    return tuple(
        dict.fromkeys(
            (*NODE_ADVERTISEMENT_GOSSIP_PEERS, *CHALLENGE_ASSIGNMENT_GOSSIP_PEERS)
        )
    )


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
            "Operational Credential gossip peer must be an http(s) origin without credentials"
        )
    return value.rstrip("/")


def build_operational_credential_gossip(
    *, after_sequence: int = 0, limit: int = 100
) -> dict[str, Any]:
    states = list_operational_credential_states(
        after_sequence=after_sequence,
        limit=limit,
    )
    head_sequence = operational_credential_latest_sequence()
    return {"states": states, "head_sequence": head_sequence}


def ingest_operational_credential_gossip(item: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "sequence",
        "state",
        "state_hash",
        "stored_at",
    }:
        raise HTTPException(status_code=400, detail="invalid Operational Credential gossip item")
    state = item.get("state")
    if not isinstance(state, Mapping):
        raise HTTPException(status_code=400, detail="invalid Operational Credential gossip state")
    try:
        expected_digest = operational_credential_state_hash(state)
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid Operational Credential state") from exc
    if item.get("state_hash") != expected_digest:
        raise HTTPException(status_code=400, detail="Operational Credential gossip hash mismatch")
    try:
        digest, accepted = publish_operational_credential_state(state)
    except OperationalCredentialConflict as exc:
        get_network_view_guard().force_freeze(
            "conflicting root-signed Operational Credential states detected"
        )
        raise HTTPException(status_code=409, detail=str(exc))
    except OperationalCredentialRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    return {
        "node_id": state["node_id"],
        "credential_epoch": state["credential_epoch"],
        "state_hash": digest,
        "accepted": accepted,
    }


async def poll_operational_credential_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured = tuple(
        _validated_peer_url(peer)
        for peer in (peers or _configured_peers())
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(
            timeout=max(
                NODE_ADVERTISEMENT_GOSSIP_TIMEOUT_SECONDS,
                CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS,
            ),
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
                    items = payload.get("states")
                    head = payload.get("head_sequence")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < cursor
                    ):
                        raise ValueError("invalid Operational Credential gossip response")
                    for item in items:
                        sequence = item.get("sequence") if isinstance(item, Mapping) else None
                        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= cursor:
                            raise ValueError("invalid Operational Credential gossip sequence")
                        result = ingest_operational_credential_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        cursor = sequence
                    _peer_cursors[peer] = cursor
                    if not items or len(items) < 100:
                        break
                else:
                    raise ValueError("Operational Credential gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("Operational Credential gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_operational_credential_peers_once()
        except Exception as exc:
            logger.warning("Operational Credential gossip cycle failed: %s", exc)
        await asyncio.sleep(
            min(
                NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS,
                CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS,
            )
        )


def start_operational_credential_gossip() -> asyncio.Task | None:
    enabled = NODE_ADVERTISEMENT_GOSSIP_ENABLED or CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED
    peers = _configured_peers()
    if not enabled or not peers:
        return None
    for peer in peers:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
