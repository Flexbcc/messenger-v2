"""Fail-closed provider boundary for an externally reviewed Sphinx layer."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol, Sequence


@dataclass(frozen=True)
class OnionHop:
    node_id: str
    public_key: bytes
    capability: str


@dataclass(frozen=True)
class UnwrappedHop:
    next_node_id: str | None
    next_capability: str | None
    next_packet: bytes | None
    final_payload: bytes | None
    replay_tag: bytes
    expires_at: datetime


@dataclass(frozen=True)
class ReplyPacket:
    first_node_id: str
    packet: bytes
    expires_at: datetime


@dataclass(frozen=True)
class ReplyBlock:
    surb: bytes
    expires_at: datetime


class OnionPacketProvider(Protocol):
    provider_id: str

    async def build(
        self, *, route: Sequence[OnionHop], payload: bytes, expires_at: datetime
    ) -> bytes: ...

    async def unwrap(self, *, private_key: bytes, packet: bytes) -> UnwrappedHop: ...

    async def build_reply(self, *, surb: bytes, payload: bytes) -> ReplyPacket: ...

    async def create_reply_block(
        self,
        *,
        route: Sequence[OnionHop],
        expires_at: datetime,
        packet_size: int,
    ) -> ReplyBlock: ...


class UnavailableOnionProvider:
    provider_id = "unavailable"

    async def build(
        self, *, route: Sequence[OnionHop], payload: bytes, expires_at: datetime
    ) -> bytes:
        raise RuntimeError("reviewed Sphinx packet provider is not configured")

    async def unwrap(self, *, private_key: bytes, packet: bytes) -> UnwrappedHop:
        raise RuntimeError("reviewed Sphinx packet provider is not configured")

    async def build_reply(self, *, surb: bytes, payload: bytes) -> ReplyPacket:
        raise RuntimeError("reviewed Sphinx packet provider is not configured")

    async def create_reply_block(
        self,
        *,
        route: Sequence[OnionHop],
        expires_at: datetime,
        packet_size: int,
    ) -> ReplyBlock:
        raise RuntimeError("reviewed Sphinx packet provider is not configured")
