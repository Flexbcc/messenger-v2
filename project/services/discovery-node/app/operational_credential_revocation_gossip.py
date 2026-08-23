"""Bounded pull gossip for quorum Operational Credential revocations."""

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
from app.operational_credential_revocation_store import (
    OperationalCredentialRevocationConflict,
    OperationalCredentialRevocationRollback,
    list_operational_credential_revocations,
    operational_credential_revocation_latest_sequence,
    publish_operational_credential_revocation,
)
from shared.security.operational_credential_revocation import (
    operational_credential_revocation_hash,
)


GOSSIP_PATH = "/registry/operational-credential-revocations/gossip"
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
            "Operational Credential revocation gossip peer must be an http(s) origin without credentials"
        )
    return value.rstrip("/")


def build_operational_credential_revocation_gossip(
    *, after_sequence: int = 0, limit: int = 100
) -> dict[str, Any]:
    return {
        "revocations": list_operational_credential_revocations(
            after_sequence=after_sequence, limit=limit
        ),
        "head_sequence": operational_credential_revocation_latest_sequence(),
    }


def ingest_operational_credential_revocation_gossip(
    item: Mapping[str, Any],
) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "sequence",
        "revocation",
        "revocation_hash",
        "stored_at",
    }:
        raise HTTPException(status_code=400, detail="invalid credential revocation gossip item")
    sequence = item.get("sequence")
    revocation = item.get("revocation")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 1
        or not isinstance(revocation, Mapping)
    ):
        raise HTTPException(status_code=400, detail="invalid credential revocation gossip item")
    try:
        expected = operational_credential_revocation_hash(revocation)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid credential revocation") from exc
    if item.get("revocation_hash") != expected:
        raise HTTPException(status_code=400, detail="credential revocation gossip hash mismatch")
    try:
        digest, accepted = publish_operational_credential_revocation(revocation)
    except OperationalCredentialRevocationConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except OperationalCredentialRevocationRollback as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    return {
        "sequence": sequence,
        "node_id": revocation["node_id"],
        "revocation_epoch": revocation["revocation_epoch"],
        "revocation_hash": digest,
        "accepted": accepted,
    }


async def poll_operational_credential_revocation_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured = tuple(_validated_peer_url(peer) for peer in (peers or _configured_peers()))
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
                    items = payload.get("revocations")
                    head = payload.get("head_sequence")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < cursor
                    ):
                        raise ValueError("invalid credential revocation gossip response")
                    for item in items:
                        sequence = item.get("sequence") if isinstance(item, Mapping) else None
                        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= cursor:
                            raise ValueError("invalid credential revocation gossip sequence")
                        result = ingest_operational_credential_revocation_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        cursor = sequence
                    _peer_cursors[peer] = cursor
                    if not items or len(items) < 100:
                        break
                else:
                    raise ValueError("credential revocation gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("credential revocation gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {"fetched": fetched, "accepted": accepted, "failed_peers": failed}


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_operational_credential_revocation_peers_once()
        except Exception as exc:
            logger.warning("credential revocation gossip cycle failed: %s", exc)
        await asyncio.sleep(
            min(
                NODE_ADVERTISEMENT_GOSSIP_INTERVAL_SECONDS,
                CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS,
            )
        )


def start_operational_credential_revocation_gossip() -> asyncio.Task | None:
    enabled = NODE_ADVERTISEMENT_GOSSIP_ENABLED or CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED
    peers = _configured_peers()
    if not enabled or not peers:
        return None
    for peer in peers:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
