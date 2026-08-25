"""Bounded D1/D2/D3 replication for endpoint-signed rendezvous records."""

import asyncio
import logging
from urllib.parse import urlsplit

import httpx
from shared.security.outbound_tls import outbound_tls_verify

from app.bootstrap_record_store import (
    BootstrapRecordConflict,
    list_bootstrap_records,
    publish_bootstrap_record,
)
from app.config import (
    RENDEZVOUS_GOSSIP_ENABLED,
    RENDEZVOUS_GOSSIP_INTERVAL_SECONDS,
    RENDEZVOUS_GOSSIP_PEERS,
    RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS,
)
from app.network_guard import get_network_view_guard
from app.route_descriptor_store import (
    RouteDescriptorConflict,
    RouteDescriptorIdentityUnavailable,
    list_route_descriptor_gossip,
    publish_route_descriptor,
)


logger = logging.getLogger(__name__)
MAX_PAGES = 10


def _origin(value: str) -> str:
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
        raise ValueError("rendezvous gossip peer must be an http(s) origin")
    return value.rstrip("/")


def local_rendezvous_page(
    *, after_user_id: str = "", after_route_sequence: int = 0, limit: int = 100
) -> dict:
    return {
        "bootstrap_records": list_bootstrap_records(
            after_user_id=after_user_id, limit=limit
        ),
        "route_descriptors": list_route_descriptor_gossip(
            after_sequence=after_route_sequence, limit=limit
        ),
    }


def ingest_rendezvous_page(payload: dict) -> tuple[int, int]:
    if not isinstance(payload, dict) or set(payload) != {
        "bootstrap_records",
        "route_descriptors",
    }:
        raise ValueError("invalid rendezvous gossip page")
    bootstrap = payload["bootstrap_records"]
    routes = payload["route_descriptors"]
    if not isinstance(bootstrap, list) or not isinstance(routes, list):
        raise ValueError("invalid rendezvous gossip collections")
    if len(bootstrap) > 100 or len(routes) > 100:
        raise ValueError("rendezvous gossip page exceeds limit")
    accepted_bootstrap = 0
    accepted_routes = 0
    for record in bootstrap:
        try:
            accepted_bootstrap += int(publish_bootstrap_record(record)["accepted"])
        except BootstrapRecordConflict:
            get_network_view_guard().force_freeze("BootstrapRecord split view detected")
            raise
    for item in routes:
        if not isinstance(item, dict) or set(item) != {"sequence", "descriptor"}:
            raise ValueError("invalid RouteDescriptor gossip item")
        try:
            accepted_routes += int(
                publish_route_descriptor(item["descriptor"])["accepted"]
            )
        except RouteDescriptorConflict:
            get_network_view_guard().force_freeze("RouteDescriptor split view detected")
            raise
        except RouteDescriptorIdentityUnavailable:
            # Its BootstrapRecord can arrive on a later bounded page.
            continue
    return accepted_bootstrap, accepted_routes


async def _sync_peer(client: httpx.AsyncClient, peer: str) -> None:
    after_user_id = ""
    after_route_sequence = 0
    for _ in range(MAX_PAGES):
        response = await client.get(
            f"{peer}/registry/rendezvous/gossip",
            params={
                "after_user_id": after_user_id,
                "after_route_sequence": after_route_sequence,
                "limit": 100,
            },
        )
        response.raise_for_status()
        page = response.json()
        ingest_rendezvous_page(page)
        bootstrap = page["bootstrap_records"]
        routes = page["route_descriptors"]
        if bootstrap:
            after_user_id = max(item["user_id"] for item in bootstrap)
        if routes:
            after_route_sequence = max(item["sequence"] for item in routes)
        if len(bootstrap) < 100 and len(routes) < 100:
            break


async def _loop() -> None:
    peers = tuple(_origin(peer) for peer in RENDEZVOUS_GOSSIP_PEERS)
    while True:
        async with httpx.AsyncClient(
            timeout=RENDEZVOUS_GOSSIP_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False, verify=outbound_tls_verify(),
        ) as client:
            for peer in peers:
                try:
                    await _sync_peer(client, peer)
                except Exception as exc:
                    logger.warning("Rendezvous gossip from %s failed: %s", peer, exc)
        await asyncio.sleep(RENDEZVOUS_GOSSIP_INTERVAL_SECONDS)


def start_rendezvous_gossip() -> asyncio.Task | None:
    if RENDEZVOUS_GOSSIP_ENABLED and RENDEZVOUS_GOSSIP_PEERS:
        return asyncio.create_task(_loop())
    return None
