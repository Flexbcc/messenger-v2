"""Provider-neutral opaque ingress processing and delayed dispatch runtime."""

from __future__ import annotations

import base64
import json
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Mapping

from shared.transport.mix_pool import MixPool, MixPoolFull
from shared.transport.onion_provider import OnionPacketProvider
from shared.transport.opaque_ingress import (
    PACKET_SIZES,
    validate_opaque_ingress_packet,
)
from shared.transport.replay_tag_store import ReplayTagStore


NextHopSender = Callable[[str, str, bytes, datetime], Awaitable[None]]
FinalDelivery = Callable[[bytes], Awaitable[None]]


class MixIngressRuntime:
    def __init__(
        self,
        *,
        provider: OnionPacketProvider,
        private_key: bytes,
        replay_store: ReplayTagStore,
        pool: MixPool,
        next_hop_sender: NextHopSender,
        final_delivery: FinalDelivery,
        cell_lifetime_seconds: float = 300,
    ) -> None:
        if not isinstance(private_key, bytes) or len(private_key) != 32:
            raise ValueError("transport private key must be 32 bytes")
        if not 1 <= cell_lifetime_seconds <= 300:
            raise ValueError("invalid Mix cell lifetime")
        self.provider = provider
        self.private_key = private_key
        self.replay_store = replay_store
        self.pool = pool
        self.next_hop_sender = next_hop_sender
        self.final_delivery = final_delivery
        self.cell_lifetime_seconds = cell_lifetime_seconds

    async def admit(
        self, envelope: Mapping[str, Any], *, is_cover: bool = False
    ) -> None:
        now = datetime.now(timezone.utc)
        ingress = validate_opaque_ingress_packet(envelope, now=now)
        unwrapped = await self.provider.unwrap(
            private_key=self.private_key, packet=ingress.packet
        )
        if unwrapped.expires_at != ingress.expires_at:
            raise ValueError("onion and ingress expiry mismatch")
        if not self.replay_store.consume(unwrapped.replay_tag):
            raise ValueError("per-hop onion replay detected")
        next_present = (
            unwrapped.next_node_id is not None
            or unwrapped.next_capability is not None
            or unwrapped.next_packet is not None
        )
        final_present = unwrapped.final_payload is not None
        if next_present == final_present:
            raise ValueError("onion unwrap must produce exactly one dispatch type")
        if next_present:
            if (
                not isinstance(unwrapped.next_node_id, str)
                or not 1 <= len(unwrapped.next_node_id) <= 256
                or unwrapped.next_capability not in {"relay", "home"}
                or not isinstance(unwrapped.next_packet, bytes)
                or len(unwrapped.next_packet) not in PACKET_SIZES
            ):
                raise ValueError("invalid next-hop onion dispatch")
            dispatch = {
                "kind": "next",
                "node_id": unwrapped.next_node_id,
                "capability": unwrapped.next_capability,
                "payload": base64.urlsafe_b64encode(unwrapped.next_packet).decode(),
                "expires_at": unwrapped.expires_at.isoformat().replace("+00:00", "Z"),
            }
        else:
            if (
                not isinstance(unwrapped.final_payload, bytes)
                or not 1 <= len(unwrapped.final_payload) <= 96 * 1024
            ):
                raise ValueError("invalid final onion payload")
            dispatch = {
                "kind": "final",
                "payload": base64.urlsafe_b64encode(unwrapped.final_payload).decode(),
            }
        try:
            remaining_lifetime = max(
                0.001,
                min(
                    self.cell_lifetime_seconds,
                    (unwrapped.expires_at - now).total_seconds(),
                ),
            )
            await self.pool.enqueue(
                json.dumps(dispatch, separators=(",", ":")).encode(),
                lifetime_seconds=remaining_lifetime,
                is_cover=is_cover,
            )
        except MixPoolFull:
            # The packet was authenticated and unwrapped but never admitted.
            # Permit a later retry after backpressure clears without weakening
            # the replay window for packets that did enter the pool.
            self.replay_store.release(unwrapped.replay_tag)
            raise

    async def drain(self, *, batch_limit: int) -> int:
        return await self.pool.drain_ready(self._dispatch, batch_limit=batch_limit)

    async def _dispatch(self, encoded: bytes) -> None:
        try:
            value = json.loads(encoded)
            if not isinstance(value, dict):
                raise ValueError("internal Mix dispatch must be an object")
            payload = base64.b64decode(
                value["payload"], altchars=b"-_", validate=True
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ValueError("invalid internal Mix dispatch") from exc
        if value.get("kind") == "next":
            if set(value) != {
                "kind", "node_id", "capability", "payload", "expires_at"
            }:
                raise ValueError("invalid internal next-hop fields")
            node_id = value.get("node_id")
            if not isinstance(node_id, str) or not 1 <= len(node_id) <= 256:
                raise ValueError("invalid internal next-hop NodeID")
            capability = value.get("capability")
            if capability not in {"relay", "home"}:
                raise ValueError("invalid internal next-hop capability")
            expires_at = _parse_internal_expiry(value.get("expires_at"))
            await self.next_hop_sender(node_id, capability, payload, expires_at)
            return
        if value.get("kind") == "final":
            if set(value) != {"kind", "payload"}:
                raise ValueError("invalid internal final fields")
            await self.final_delivery(payload)
            return
        raise ValueError("invalid internal Mix dispatch kind")

    async def health(self) -> dict[str, Any]:
        state = await self.pool.health()
        return {"provider": self.provider.provider_id, "pool": state}


def _parse_internal_expiry(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("missing internal Mix expiry")
    try:
        parsed = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
    except ValueError as exc:
        raise ValueError("invalid internal Mix expiry") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("internal Mix expiry must include timezone")
    return parsed.astimezone(timezone.utc)
