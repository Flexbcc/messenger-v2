"""Fail-closed boundary for a reviewed systematic K-of-N codec."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, Sequence


@dataclass(frozen=True)
class ErasureShard:
    index: int
    required: int
    total: int
    data: bytes


class ErasureCodecProvider(Protocol):
    provider_id: str

    async def encode(self, payload: bytes, *, required: int, total: int) -> Sequence[ErasureShard]: ...

    async def reconstruct(self, shards: Sequence[ErasureShard]) -> bytes: ...


class UnavailableErasureCodec:
    provider_id = "unavailable"

    async def encode(self, payload: bytes, *, required: int, total: int) -> Sequence[ErasureShard]:
        raise RuntimeError("reviewed K-of-N codec provider is not configured")

    async def reconstruct(self, shards: Sequence[ErasureShard]) -> bytes:
        raise RuntimeError("reviewed K-of-N codec provider is not configured")


def validate_erasure_parameters(*, required: int, total: int) -> None:
    if (
        not isinstance(required, int)
        or isinstance(required, bool)
        or not isinstance(total, int)
        or isinstance(total, bool)
        or not 2 <= required <= total <= 64
    ):
        raise ValueError("K-of-N parameters must satisfy 2 <= K <= N <= 64")
