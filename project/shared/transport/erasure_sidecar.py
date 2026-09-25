"""Validated K-of-N adapter over the persistent Rust transport sidecar."""

from __future__ import annotations

import base64
from typing import Any, Sequence

from shared.transport.erasure_provider import ErasureShard, validate_erasure_parameters
from shared.transport.onion_sidecar import (
    OnionSidecarProvider,
    require_sidecar_response_fields,
)

MAX_CONTAINER_BYTES = 4 * 1024 * 1024
MAX_SHARD_BYTES = 1024 * 1024


class ErasureSidecarProvider:
    provider_id = "ouo-rust-reed-solomon-sidecar/1"

    def __init__(self, sidecar: OnionSidecarProvider) -> None:
        self.sidecar = sidecar

    async def encode(
        self, payload: bytes, *, required: int, total: int
    ) -> Sequence[ErasureShard]:
        validate_erasure_parameters(required=required, total=total)
        if not isinstance(payload, bytes) or not 1 <= len(payload) <= MAX_CONTAINER_BYTES:
            raise ValueError("invalid erasure container size")
        response = await self.sidecar.request_operation(
            "erasure_encode",
            {"required": required, "total": total,
             "payload_b64": base64.urlsafe_b64encode(payload).decode()},
        )
        require_sidecar_response_fields(response, {"shards"})
        raw = response.get("shards")
        if not isinstance(raw, list) or len(raw) != total:
            raise ValueError("sidecar returned invalid shard count")
        shards = tuple(_decode_shard(item, required, total) for item in raw)
        if {item.index for item in shards} != set(range(total)):
            raise ValueError("sidecar returned duplicate or missing shard indexes")
        if len({len(item.data) for item in shards}) != 1:
            raise ValueError("sidecar returned unequal shard sizes")
        return shards

    async def reconstruct(self, shards: Sequence[ErasureShard]) -> bytes:
        if not shards:
            raise ValueError("no erasure shards supplied")
        required, total = shards[0].required, shards[0].total
        validate_erasure_parameters(required=required, total=total)
        if not required <= len(shards) <= total:
            raise ValueError("insufficient or excessive erasure shards")
        if len({item.index for item in shards}) != len(shards):
            raise ValueError("duplicate erasure shard index")
        for item in shards:
            if (
                item.required != required or item.total != total
                or not 0 <= item.index < total
                or not 1 <= len(item.data) <= MAX_SHARD_BYTES
            ):
                raise ValueError("inconsistent erasure shard set")
        response = await self.sidecar.request_operation(
            "erasure_reconstruct",
            {"required": required, "total": total,
             "shards": [{"index": item.index,
                          "data_b64": base64.urlsafe_b64encode(item.data).decode()}
                         for item in shards]},
        )
        require_sidecar_response_fields(response, {"payload_b64"})
        payload = _decode(response.get("payload_b64"), "reconstructed payload")
        if not 1 <= len(payload) <= MAX_CONTAINER_BYTES:
            raise ValueError("invalid reconstructed payload size")
        return payload


def _decode_shard(value: Any, required: int, total: int) -> ErasureShard:
    if not isinstance(value, dict) or set(value) != {"index", "data_b64"}:
        raise ValueError("invalid sidecar shard")
    index = value.get("index")
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < total:
        raise ValueError("invalid sidecar shard index")
    data = _decode(value.get("data_b64"), "shard")
    if not 1 <= len(data) <= MAX_SHARD_BYTES:
        raise ValueError("invalid sidecar shard size")
    return ErasureShard(index, required, total, data)


def _decode(value: Any, label: str) -> bytes:
    if not isinstance(value, str):
        raise ValueError(f"missing {label}")
    try:
        return base64.b64decode(value, altchars=b"-_", validate=True)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid {label}") from exc
