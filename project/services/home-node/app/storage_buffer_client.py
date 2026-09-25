"""Replicated Storage-node buffer protocol for Home-node."""

import asyncio
import hashlib
import json
import logging
from typing import Awaitable, Callable

import httpx

from shared.security.http_client import federation_delete, federation_get, federation_post
from shared.security.http_response import parse_bounded_json_response
from shared.security.outbound_tls import outbound_tls_verify
from shared.security.payload_builder import build_buffer_payload

logger = logging.getLogger(__name__)


async def buffer_for_offline_user(
    user_id: str,
    envelope: dict,
    *,
    storage_urls: list[str],
    write_quorum: int,
    signing_key,
    node_id: str,
    ttl_seconds: int = 24 * 60 * 60,
) -> None:
    payload = build_buffer_payload(
        signing_key=signing_key,
        origin_node_id=node_id,
        recipient_device_id=user_id,
        envelope=envelope,
        ttl_seconds=ttl_seconds,
    )

    async def store(storage_url: str) -> None:
        try:
            async with httpx.AsyncClient(
                timeout=5.0,
                follow_redirects=False,
                trust_env=False,
                verify=outbound_tls_verify(),
            ) as client:
                response = await federation_post(
                    client,
                    f"{storage_url}/buffer",
                    path="/buffer",
                    payload=payload,
                    signing_key=signing_key,
                    node_id=node_id,
                )
                if response.status_code >= 400:
                    logger.warning(
                        "Storage rejected buffer request with HTTP %s: %s",
                        response.status_code,
                        response.text[:512],
                    )
                response.raise_for_status()
        except Exception as exc:
            logger.warning(
                "Failed to buffer message for %s on %s: %s",
                user_id,
                storage_url,
                exc,
            )
            raise

    results = await asyncio.gather(
        *(store(storage_url) for storage_url in storage_urls),
        return_exceptions=True,
    )
    successful = sum(not isinstance(result, BaseException) for result in results)
    if successful < write_quorum:
        raise RuntimeError(
            "Storage write quorum was not reached "
            f"({successful}/{write_quorum})"
        )


async def drain_buffer(
    user_id: str,
    deliver: Callable[[dict], Awaitable[bool]],
    *,
    storage_urls: list[str],
    signing_key,
    node_id: str,
) -> None:
    """Offer each distinct mailbox packet to the connected device.

    A successful WebSocket write is only Home-side handoff, not a semantic
    device acknowledgement. Storage copies therefore remain until
    ``purge_buffered_packet`` is called by the ACK endpoint or their TTL
    expires. This can produce a duplicate after reconnect; packet-id dedupe
    and idempotent ACK make that safer than deleting an unacknowledged packet.
    """
    copies_by_packet: dict[str, dict] = {}
    for storage_url in storage_urls:
        try:
            async with httpx.AsyncClient(
                timeout=5.0,
                follow_redirects=False,
                trust_env=False,
                verify=outbound_tls_verify(),
            ) as client:
                response = await federation_get(
                    client,
                    f"{storage_url}/buffer/{user_id}",
                    path=f"/buffer/{user_id}",
                    signing_key=signing_key,
                    node_id=node_id,
                )
            if response.status_code != 200:
                continue
            body = parse_bounded_json_response(response, max_bytes=1024 * 1024)
            entries = body.get("envelopes") if isinstance(body, dict) else None
            if not isinstance(entries, list):
                raise ValueError("invalid Storage buffer response")
            for entry in entries:
                if not isinstance(entry, dict) or not isinstance(entry.get("envelope"), dict):
                    raise ValueError("invalid Storage buffer entry")
                entry_id = entry.get("id")
                if not isinstance(entry_id, str) or not entry_id:
                    raise ValueError("invalid Storage buffer entry id")
                envelope = entry["envelope"]
                packet_id = envelope.get("packet_id")
                if not isinstance(packet_id, str) or not packet_id:
                    packet_id = hashlib.sha256(
                        json.dumps(
                            envelope,
                            sort_keys=True,
                            separators=(",", ":"),
                        ).encode("utf-8")
                    ).hexdigest()
                group = copies_by_packet.setdefault(
                    packet_id,
                    {"envelope": envelope, "copies": []},
                )
                group["copies"].append((storage_url, entry_id))
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            logger.warning(
                "Failed to drain buffer for %s from %s: %s",
                user_id,
                storage_url,
                exc,
            )

    for group in copies_by_packet.values():
        try:
            await deliver(group["envelope"])
        except Exception:
            continue


async def purge_buffered_packet(
    user_id: str,
    packet_id: str,
    *,
    storage_urls: list[str],
    signing_key,
    node_id: str,
) -> int:
    """Delete this recipient's replicated mailbox copies after device ACK.

    The requesting Home must pass Storage's recipient-ownership check on both
    fetch and delete. Missing/already-deleted copies are idempotent. Failures
    are logged and left for the 24-hour TTL sweep rather than failing an ACK
    already persisted by Home.
    """
    async def purge_replica(storage_url: str) -> int:
        replica_deleted = 0
        try:
            async with httpx.AsyncClient(
                timeout=5.0,
                follow_redirects=False,
                trust_env=False,
                verify=outbound_tls_verify(),
            ) as client:
                response = await federation_get(
                    client,
                    f"{storage_url}/buffer/{user_id}",
                    path=f"/buffer/{user_id}",
                    signing_key=signing_key,
                    node_id=node_id,
                )
                response.raise_for_status()
                body = parse_bounded_json_response(response, max_bytes=1024 * 1024)
                entries = body.get("envelopes") if isinstance(body, dict) else None
                if not isinstance(entries, list):
                    raise ValueError("invalid Storage buffer response")
                entry_ids = [
                    entry.get("id")
                    for entry in entries
                    if isinstance(entry, dict)
                    and isinstance(entry.get("envelope"), dict)
                    and entry["envelope"].get("packet_id") == packet_id
                    and isinstance(entry.get("id"), str)
                    and entry.get("id")
                ]
                for entry_id in entry_ids:
                    delete_response = await federation_delete(
                        client,
                        f"{storage_url}/buffer/{entry_id}",
                        path=f"/buffer/{entry_id}",
                        signing_key=signing_key,
                        node_id=node_id,
                    )
                    if delete_response.status_code == 404:
                        continue
                    delete_response.raise_for_status()
                    replica_deleted += 1
                return replica_deleted
        except (httpx.HTTPError, KeyError, TypeError, ValueError) as exc:
            logger.warning(
                "Failed to purge acknowledged packet %s for %s from %s: %s",
                packet_id,
                user_id,
                storage_url,
                exc,
            )
            return 0

    results = await asyncio.gather(
        *(purge_replica(storage_url) for storage_url in storage_urls)
    )
    return sum(results)
