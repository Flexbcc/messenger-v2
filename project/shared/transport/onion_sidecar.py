"""Persistent bounded Unix-socket adapter for a reviewed Rust onion provider."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import stat as stat_module
import struct
import uuid
from datetime import datetime, timezone
from typing import Any, Sequence

from shared.transport.onion_provider import OnionHop, ReplyPacket, UnwrappedHop
from shared.transport.opaque_ingress import PACKET_SIZES


FRAME = struct.Struct(">I")
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
RESPONSE_COMMON_FIELDS = {"protocol_version", "request_id", "ok"}


class OnionSidecarProvider:
    provider_id = "ouo-rust-sphinx-sidecar/1"

    def __init__(self, socket_path: str, *, timeout_seconds: float = 5.0) -> None:
        if not socket_path or len(socket_path.encode()) > 100:
            raise ValueError("invalid onion sidecar socket path")
        if not 0.1 <= timeout_seconds <= 60:
            raise ValueError("invalid onion sidecar timeout")
        self.socket_path = socket_path
        self.timeout_seconds = timeout_seconds
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._lock = asyncio.Lock()

    async def _connect(self) -> None:
        if self._writer and not self._writer.is_closing():
            return
        socket_stat = os.lstat(self.socket_path)
        if not stat_module.S_ISSOCK(socket_stat.st_mode):
            raise PermissionError("onion sidecar path is not a Unix socket")
        if socket_stat.st_uid != os.geteuid():
            raise PermissionError("onion sidecar socket owner does not match node uid")
        if socket_stat.st_mode & 0o077:
            raise PermissionError("onion sidecar socket must not be group/world accessible")
        self._reader, self._writer = await asyncio.open_unix_connection(self.socket_path)

    async def _request(self, operation: str, body: dict[str, Any]) -> dict[str, Any]:
        request_id = str(uuid.uuid4())
        encoded = json.dumps(
            {"protocol_version": "ouo-onion-sidecar/1", "request_id": request_id,
             "operation": operation, **body},
            separators=(",", ":"),
        ).encode()
        if len(encoded) > MAX_REQUEST_BYTES:
            raise ValueError("onion sidecar request exceeds limit")
        async with self._lock:
            try:
                await asyncio.wait_for(self._connect(), self.timeout_seconds)
                assert self._reader is not None and self._writer is not None
                self._writer.write(FRAME.pack(len(encoded)) + encoded)
                await asyncio.wait_for(self._writer.drain(), self.timeout_seconds)
                header = await asyncio.wait_for(
                    self._reader.readexactly(FRAME.size), self.timeout_seconds
                )
                size = FRAME.unpack(header)[0]
                if not 1 <= size <= MAX_RESPONSE_BYTES:
                    raise ValueError("invalid onion sidecar response size")
                raw = await asyncio.wait_for(
                    self._reader.readexactly(size), self.timeout_seconds
                )
            except (Exception, asyncio.CancelledError):
                await self.close()
                raise
        try:
            response = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("invalid onion sidecar response") from exc
        if (
            not isinstance(response, dict)
            or response.get("protocol_version") != "ouo-onion-sidecar/1"
            or response.get("request_id") != request_id
        ):
            raise ValueError("onion sidecar response binding failed")
        if response.get("ok") is not True:
            raise ValueError("onion sidecar rejected packet")
        return response

    async def request_operation(
        self, operation: str, body: dict[str, Any]
    ) -> dict[str, Any]:
        if operation not in {
            "build", "unwrap", "build_reply", "erasure_encode", "erasure_reconstruct"
        }:
            raise ValueError("unsupported sidecar operation")
        return await self._request(operation, body)

    async def build(
        self, *, route: Sequence[OnionHop], payload: bytes, expires_at: datetime
    ) -> bytes:
        if not 2 <= len(route) <= 5:
            raise ValueError("onion route must contain 2-5 hops")
        if not isinstance(payload, bytes) or not 1 <= len(payload) <= 96 * 1024:
            raise ValueError("invalid onion payload size")
        expiry = _format_expiry(expires_at)
        for hop in route:
            if (
                not isinstance(hop.node_id, str)
                or not 1 <= len(hop.node_id) <= 256
                or not isinstance(hop.public_key, bytes)
                or len(hop.public_key) != 32
                or hop.capability not in {"relay", "home"}
            ):
                raise ValueError("invalid onion route hop")
        if route[-1].capability != "home" or any(
            hop.capability != "relay" for hop in route[:-1]
        ):
            raise ValueError("onion route must be Relay hops followed by one Home")
        response = await self._request(
            "build",
            {
                "route": [
                    {"node_id": hop.node_id,
                     "capability": hop.capability,
                     "public_key_b64": base64.urlsafe_b64encode(hop.public_key).decode()}
                    for hop in route
                ],
                "payload_b64": base64.urlsafe_b64encode(payload).decode(),
                "expires_at": expiry,
            },
        )
        _require_response_fields(response, {"packet_b64"})
        packet = _decode(response.get("packet_b64"), "packet")
        if len(packet) not in PACKET_SIZES:
            raise ValueError("sidecar returned unsupported packet size")
        return packet

    async def unwrap(self, *, private_key: bytes, packet: bytes) -> UnwrappedHop:
        if not isinstance(private_key, bytes) or len(private_key) != 32:
            raise ValueError("invalid transport private key")
        if not isinstance(packet, bytes) or len(packet) not in PACKET_SIZES:
            raise ValueError("invalid fixed-size onion packet")
        response = await self._request(
            "unwrap",
            {
                "private_key_b64": base64.urlsafe_b64encode(private_key).decode(),
                "packet_b64": base64.urlsafe_b64encode(packet).decode(),
            },
        )
        _require_response_fields(
            response,
            {
                "next_node_id",
                "next_capability",
                "next_packet_b64",
                "final_payload_b64",
                "replay_tag_b64",
                "expires_at",
            },
        )
        next_packet = response.get("next_packet_b64")
        final_payload = response.get("final_payload_b64")
        result = UnwrappedHop(
            next_node_id=response.get("next_node_id"),
            next_capability=response.get("next_capability"),
            next_packet=_decode(next_packet, "next packet") if next_packet is not None else None,
            final_payload=_decode(final_payload, "final payload") if final_payload is not None else None,
            replay_tag=_decode(response.get("replay_tag_b64"), "replay tag"),
            expires_at=_parse_expiry(response.get("expires_at")),
        )
        next_present = (
            result.next_node_id is not None
            or result.next_capability is not None
            or result.next_packet is not None
        )
        final_present = result.final_payload is not None
        if next_present == final_present:
            raise ValueError("sidecar returned ambiguous onion dispatch")
        if next_present and (
            not isinstance(result.next_node_id, str)
            or not 1 <= len(result.next_node_id) <= 256
            or result.next_capability not in {"relay", "home"}
            or not isinstance(result.next_packet, bytes)
            or len(result.next_packet) not in PACKET_SIZES
        ):
            raise ValueError("sidecar returned invalid next-hop dispatch")
        if not next_present and result.next_capability is not None:
            raise ValueError("final onion dispatch cannot include next capability")
        if final_present and not 1 <= len(result.final_payload or b"") <= 96 * 1024:
            raise ValueError("sidecar returned invalid final payload")
        if not 16 <= len(result.replay_tag) <= 64:
            raise ValueError("sidecar returned invalid replay tag")
        return result

    async def build_reply(self, *, surb: bytes, payload: bytes) -> ReplyPacket:
        if not isinstance(surb, bytes) or not 1 <= len(surb) <= 256 * 1024:
            raise ValueError("invalid SURB size")
        if not isinstance(payload, bytes) or not 1 <= len(payload) <= 96 * 1024:
            raise ValueError("invalid SURB payload size")
        response = await self._request(
            "build_reply",
            {
                "surb_b64": base64.urlsafe_b64encode(surb).decode(),
                "payload_b64": base64.urlsafe_b64encode(payload).decode(),
            },
        )
        _require_response_fields(
            response, {"first_node_id", "packet_b64", "expires_at"}
        )
        first_node_id = response.get("first_node_id")
        if not isinstance(first_node_id, str) or not 1 <= len(first_node_id) <= 256:
            raise ValueError("invalid SURB first node")
        packet = _decode(response.get("packet_b64"), "reply packet")
        if len(packet) not in PACKET_SIZES:
            raise ValueError("sidecar returned unsupported reply packet size")
        return ReplyPacket(
            first_node_id=first_node_id,
            packet=packet,
            expires_at=_parse_expiry(response.get("expires_at")),
        )

    async def close(self) -> None:
        writer = self._writer
        self._reader = None
        self._writer = None
        if writer:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, BrokenPipeError):
                pass


def _decode(value: Any, label: str) -> bytes:
    if not isinstance(value, str):
        raise ValueError(f"missing onion sidecar {label}")
    try:
        return base64.b64decode(value, altchars=b"-_", validate=True)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid onion sidecar {label}") from exc


def _format_expiry(value: datetime) -> str:
    if (
        not isinstance(value, datetime)
        or value.tzinfo is None
        or value.utcoffset() is None
    ):
        raise ValueError("onion expiry must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_expiry(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("missing authenticated onion expiry")
    try:
        parsed = datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
    except ValueError as exc:
        raise ValueError("invalid authenticated onion expiry") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("authenticated onion expiry must include timezone")
    return parsed.astimezone(timezone.utc)


def require_sidecar_response_fields(
    response: dict[str, Any], operation_fields: set[str]
) -> None:
    _require_response_fields(response, operation_fields)


def _require_response_fields(
    response: dict[str, Any], operation_fields: set[str]
) -> None:
    if set(response) != RESPONSE_COMMON_FIELDS | operation_fields:
        raise ValueError("invalid onion sidecar response fields")
