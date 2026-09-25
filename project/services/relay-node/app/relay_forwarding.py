"""Validation and hub selection primitives for Relay packet forwarding."""

import asyncio
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException
from shared.security.outbound_tls import outbound_tls_verify

MAX_HOPS = 2
HUB_PING_TIMEOUT_SECONDS = 3.0


def normalize_target_url(value: object) -> str:
    if not isinstance(value, str) or len(value) > 2048:
        raise HTTPException(status_code=400, detail="invalid target_home_node_url")
    parsed = urlsplit(value)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        raise HTTPException(status_code=400, detail="invalid target_home_node_url")
    if parsed.query or parsed.fragment or parsed.path not in ("", "/"):
        raise HTTPException(
            status_code=400,
            detail="target_home_node_url must be an origin without path/query/fragment",
        )
    return f"{parsed.scheme}://{parsed.netloc}"


def validate_forward_payload(
    payload: object,
) -> tuple[str, int, dict, dict, dict | None]:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="forward payload must be an object")
    target_url = normalize_target_url(payload.get("target_home_node_url"))
    hop_count = payload.get("hop_count", 1)
    if (
        not isinstance(hop_count, int)
        or isinstance(hop_count, bool)
        or not 1 <= hop_count <= MAX_HOPS
    ):
        raise HTTPException(
            status_code=400,
            detail=f"hop_count must be an integer between 1 and {MAX_HOPS}",
        )
    envelope = payload.get("envelope")
    conversation_meta = payload.get("conversation_meta")
    federation = payload.get("federation")
    if not isinstance(envelope, dict) or not isinstance(conversation_meta, dict):
        raise HTTPException(
            status_code=400,
            detail="envelope and conversation_meta are required objects",
        )
    if federation is not None and not isinstance(federation, dict):
        raise HTTPException(status_code=400, detail="federation must be an object")
    return target_url, hop_count, envelope, conversation_meta, federation


async def target_is_trusted_home(target_url: str) -> bool:
    from app.mix_service import trusted_home_endpoint

    return await trusted_home_endpoint(target_url)


async def list_hub_urls() -> list[str]:
    """Return quorum-observed, certificate-verified L2+ Relay URLs."""
    from app.mix_service import trusted_relay_endpoints

    return await trusted_relay_endpoints(minimum_level=2)


async def fastest_hubs(hub_urls: list[str]) -> list[str]:
    """Probe hub candidates and return live endpoints fastest-first."""
    if not hub_urls:
        return []

    async def ping(url: str) -> str:
        async with httpx.AsyncClient(
            timeout=HUB_PING_TIMEOUT_SECONDS,
            follow_redirects=False,
            trust_env=False,
            verify=outbound_tls_verify(),
        ) as client:
            response = await client.get(f"{url}/health")
            response.raise_for_status()
            return url

    ranked: list[str] = []
    pending = {asyncio.create_task(ping(url)) for url in hub_urls}
    try:
        while pending:
            done, pending = await asyncio.wait(
                pending,
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in done:
                if task.exception() is None:
                    ranked.append(task.result())
    finally:
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
    return ranked
