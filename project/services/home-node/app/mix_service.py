"""Destination Home integration for opaque Mix ingress."""

from __future__ import annotations

import asyncio
from datetime import datetime
from functools import lru_cache
from typing import Any

from app.config import settings
from app.fed_security import get_federation_security
from shared.security.transport_credentials import load_or_create_transport_key
from shared.transport.final_mailbox_dispatch import decode_final_mailbox_dispatch
from shared.transport.mix_pool import MixPool
from shared.transport.mix_runtime import MixIngressRuntime
from shared.transport.onion_provider import OnionPacketProvider, UnavailableOnionProvider
from shared.transport.opaque_mailbox_client import OpaqueMailboxClient
from shared.transport.replay_tag_store import ReplayTagStore


_provider: OnionPacketProvider = UnavailableOnionProvider()
_task: asyncio.Task | None = None
_last_error: str | None = None


def install_onion_provider(provider: OnionPacketProvider) -> None:
    global _provider
    if get_mix_runtime.cache_info().currsize:
        raise RuntimeError("cannot replace onion provider after Mix runtime creation")
    if not provider.provider_id or provider.provider_id == "unavailable":
        raise ValueError("a concrete reviewed onion provider is required")
    _provider = provider


async def _reject_transit(
    _node_id: str, _capability: str, _packet: bytes, _expires_at: datetime
) -> None:
    raise RuntimeError("Home-only node cannot relay transit Mix traffic")


async def _store_final(payload: bytes) -> None:
    dispatch = decode_final_mailbox_dispatch(payload)
    fs = get_federation_security()
    client = OpaqueMailboxClient(
        signing_key=fs.signing_key,
        node_id=fs.node_id,
        storage_urls=settings.storage_node_urls,
        replication_factor=settings.storage_replication_factor,
        write_quorum=settings.storage_write_quorum,
    )
    await client.store(
        mailbox_token=dispatch.mailbox_token,
        cell=dispatch.cell,
        ttl_seconds=dispatch.ttl_seconds,
    )


@lru_cache
def get_mix_runtime() -> MixIngressRuntime:
    private_key = load_or_create_transport_key(settings.transport_key_path)
    return MixIngressRuntime(
        provider=_provider,
        private_key=bytes(private_key),
        replay_store=ReplayTagStore(
            settings.mix_replay_db_path,
            ttl_seconds=settings.mix_replay_ttl_seconds,
            max_records=settings.mix_replay_max_records,
        ),
        pool=MixPool(
            max_cells=settings.mix_pool_max_cells,
            max_bytes=settings.mix_pool_max_bytes,
            min_delay_seconds=settings.mix_min_delay_ms / 1000,
            max_delay_seconds=settings.mix_max_delay_ms / 1000,
        ),
        next_hop_sender=_reject_transit,
        final_delivery=_store_final,
    )


async def _drain_loop() -> None:
    global _last_error
    while True:
        try:
            await get_mix_runtime().drain(batch_limit=64)
            _last_error = None
        except Exception as exc:
            _last_error = str(exc)
        await asyncio.sleep(0.05)


def start_mix_runtime() -> asyncio.Task:
    global _task
    if _task and not _task.done():
        raise RuntimeError("Mix runtime already started")
    if (
        settings.onion_provider_mode == "sidecar"
        and _provider.provider_id == "unavailable"
    ):
        from shared.transport.onion_sidecar import OnionSidecarProvider
        install_onion_provider(
            OnionSidecarProvider(settings.onion_sidecar_socket_path)
        )
    _task = asyncio.create_task(_drain_loop())
    return _task


async def stop_mix_runtime() -> None:
    global _task
    if _task:
        _task.cancel()
        await asyncio.gather(_task, return_exceptions=True)
        _task = None
    close = getattr(_provider, "close", None)
    if close is not None:
        await close()


async def mix_status() -> dict[str, Any]:
    status = await get_mix_runtime().health()
    status["last_error"] = _last_error
    return status
