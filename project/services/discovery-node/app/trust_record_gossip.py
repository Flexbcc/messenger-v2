"""Pull replication for quorum-signed TrustRecords between Discovery nodes."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException

from app.config import (
    TRUST_LEDGER_DB_PATH,
    TRUST_RECORD_GOSSIP_ENABLED,
    TRUST_RECORD_GOSSIP_INTERVAL_SECONDS,
    TRUST_RECORD_GOSSIP_PEERS,
    TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS,
)
from app.trust_record_service import ingest_trust_record
from shared.security.trust_ledger import TrustLedgerStore, trust_record_hash


GOSSIP_PATH = "/registry/trust-records/gossip"
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
        raise ValueError("TrustRecord gossip peer must be an http(s) origin without credentials")
    return value.rstrip("/")


def build_trust_record_gossip(
    *,
    after_sequence: int = 0,
    limit: int = 100,
) -> dict[str, Any]:
    store = TrustLedgerStore(TRUST_LEDGER_DB_PATH)
    return {
        "records": store.records_after_sequence(
            after_sequence=after_sequence,
            limit=limit,
        ),
        "head_sequence": store.latest_sequence(),
    }


def ingest_trust_record_gossip(item: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(item, Mapping) or set(item) != {
        "sequence",
        "record_hash",
        "record",
    }:
        raise HTTPException(status_code=400, detail="invalid TrustRecord gossip item")
    sequence = item.get("sequence")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or sequence < 1
        or not isinstance(item.get("record"), Mapping)
    ):
        raise HTTPException(status_code=400, detail="invalid TrustRecord gossip item")
    try:
        digest = trust_record_hash(item["record"])
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="invalid TrustRecord gossip record") from exc
    if item.get("record_hash") != digest:
        raise HTTPException(status_code=400, detail="TrustRecord gossip hash mismatch")
    return {"sequence": sequence, **ingest_trust_record(item["record"])}


async def poll_trust_record_peers_once(
    *,
    peers: tuple[str, ...] | None = None,
    client: httpx.AsyncClient | None = None,
) -> dict[str, int]:
    configured = tuple(
        _validated_peer_url(peer) for peer in (peers or TRUST_RECORD_GOSSIP_PEERS)
    )
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(
            timeout=TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False,
        )
    fetched = accepted = applied = failed = 0
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
                    items = payload.get("records")
                    head = payload.get("head_sequence")
                    if (
                        not isinstance(items, list)
                        or len(items) > 100
                        or not isinstance(head, int)
                        or isinstance(head, bool)
                        or head < 0
                    ):
                        raise ValueError("invalid TrustRecord gossip response")
                    if head < cursor:
                        cursor = 0
                        continue
                    for item in items:
                        result = ingest_trust_record_gossip(item)
                        fetched += 1
                        accepted += int(result["accepted"])
                        applied += int(result["applied"])
                        cursor = max(cursor, result["sequence"])
                    _peer_cursors[peer] = cursor
                    if not items or cursor >= head:
                        break
                else:
                    raise ValueError("TrustRecord gossip page limit exceeded")
            except Exception as exc:
                failed += 1
                logger.warning("TrustRecord gossip peer %s failed: %s", peer, exc)
    finally:
        if own_client:
            await client.aclose()
    return {
        "fetched": fetched,
        "accepted": accepted,
        "applied": applied,
        "failed_peers": failed,
    }


async def _gossip_loop() -> None:
    while True:
        try:
            await poll_trust_record_peers_once()
        except Exception as exc:
            logger.warning("TrustRecord gossip cycle failed: %s", exc)
        await asyncio.sleep(TRUST_RECORD_GOSSIP_INTERVAL_SECONDS)


def start_trust_record_gossip() -> asyncio.Task | None:
    if not TRUST_RECORD_GOSSIP_ENABLED or not TRUST_RECORD_GOSSIP_PEERS:
        return None
    for peer in TRUST_RECORD_GOSSIP_PEERS:
        _validated_peer_url(peer)
    return asyncio.create_task(_gossip_loop())
