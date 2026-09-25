"""Low-cost background reachability probe for the configured coturn service."""

from __future__ import annotations

import asyncio
import os
import struct
from datetime import datetime, timezone
from typing import Any

from app.config import settings


MAGIC_COOKIE = 0x2112A442
_status: dict[str, Any] = {
    "reachable": False,
    "last_checked_at": None,
    "last_error": "not checked",
}


class _StunProtocol(asyncio.DatagramProtocol):
    def __init__(self, transaction_id: bytes, future: asyncio.Future) -> None:
        self.transaction_id = transaction_id
        self.future = future

    def datagram_received(self, data: bytes, _address) -> None:
        valid = (
            len(data) >= 20
            and data[:2] == b"\x01\x01"
            and data[4:8] == struct.pack(">I", MAGIC_COOKIE)
            and data[8:20] == self.transaction_id
        )
        if not self.future.done():
            self.future.set_result(valid)

    def error_received(self, exc: Exception) -> None:
        if not self.future.done():
            self.future.set_exception(exc)


async def _probe_udp() -> bool:
    loop = asyncio.get_running_loop()
    transaction_id = os.urandom(12)
    future = loop.create_future()
    transport, _protocol = await loop.create_datagram_endpoint(
        lambda: _StunProtocol(transaction_id, future),
        remote_addr=(settings.turn_host, settings.turn_port),
    )
    try:
        request = struct.pack(">HHI12s", 0x0001, 0, MAGIC_COOKIE, transaction_id)
        transport.sendto(request)
        return bool(await asyncio.wait_for(future, timeout=2.0))
    finally:
        transport.close()


async def probe_turn() -> None:
    global _status
    try:
        if settings.enable_udp:
            reachable = await _probe_udp()
        else:
            port = settings.turn_tls_port if settings.enable_tls else settings.turn_port
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(settings.turn_host, port), timeout=2.0
            )
            writer.close()
            await writer.wait_closed()
            reachable = True
        if not reachable:
            raise RuntimeError("invalid STUN binding response")
        error = None
    except Exception as exc:
        reachable = False
        error = str(exc)
    _status = {
        "reachable": reachable,
        "last_checked_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "last_error": error,
    }


async def probe_loop() -> None:
    while True:
        await probe_turn()
        await asyncio.sleep(30)


def turn_probe_status() -> dict[str, Any]:
    return dict(_status)
