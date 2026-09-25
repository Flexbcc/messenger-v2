#!/usr/bin/env python3
"""Passive-content L4 proxy for OUO traffic-correlation experiments.

The observer forwards opaque TCP byte streams and writes metadata-only JSONL.
It never terminates TLS and never stores packet payloads.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MAX_LISTENERS = 256
MAX_LABEL_LENGTH = 128
READ_SIZE = 64 * 1024


@dataclass(frozen=True)
class Listener:
    name: str
    listen_host: str
    listen_port: int
    upstream_host: str
    upstream_port: int
    source_label: str
    target_label: str


class MetadataLog:
    def __init__(self, path: Path, *, max_bytes: int, backups: int):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._path = path
        self._max_bytes = max_bytes
        self._backups = backups
        self._handle = path.open("a", encoding="utf-8", buffering=1)
        self._lock = asyncio.Lock()

    def _rotate(self) -> None:
        self._handle.close()
        oldest = self._path.with_name(f"{self._path.name}.{self._backups}")
        oldest.unlink(missing_ok=True)
        for index in range(self._backups - 1, 0, -1):
            source = self._path.with_name(f"{self._path.name}.{index}")
            if source.exists():
                source.replace(self._path.with_name(f"{self._path.name}.{index + 1}"))
        if self._path.exists():
            self._path.replace(self._path.with_name(f"{self._path.name}.1"))
        self._handle = self._path.open("a", encoding="utf-8", buffering=1)

    async def write(self, event: dict[str, Any]) -> None:
        event = {"observed_at": time.time(), **event}
        encoded = json.dumps(event, separators=(",", ":"), sort_keys=True)
        async with self._lock:
            encoded_size = len(encoded.encode("utf-8")) + 1
            if self._handle.tell() + encoded_size > self._max_bytes:
                self._rotate()
            self._handle.write(encoded + "\n")

    def close(self) -> None:
        self._handle.close()


def _bounded_label(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > MAX_LABEL_LENGTH:
        raise ValueError(f"{field} must be a non-empty string up to {MAX_LABEL_LENGTH} characters")
    return value


def _port(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 65535:
        raise ValueError(f"{field} must be a TCP port")
    return value


def load_config(path: Path) -> list[Listener]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    entries = raw.get("listeners") if isinstance(raw, dict) else None
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_LISTENERS:
        raise ValueError(f"listeners must contain 1..{MAX_LISTENERS} entries")
    listeners: list[Listener] = []
    endpoints: set[tuple[str, int]] = set()
    for item in entries:
        if not isinstance(item, dict):
            raise ValueError("listener entry must be an object")
        listener = Listener(
            name=_bounded_label(item.get("name"), "name"),
            listen_host=_bounded_label(item.get("listen_host", "0.0.0.0"), "listen_host"),
            listen_port=_port(item.get("listen_port"), "listen_port"),
            upstream_host=_bounded_label(item.get("upstream_host"), "upstream_host"),
            upstream_port=_port(item.get("upstream_port"), "upstream_port"),
            source_label=_bounded_label(item.get("source_label", "unknown"), "source_label"),
            target_label=_bounded_label(item.get("target_label", item.get("name")), "target_label"),
        )
        endpoint = (listener.listen_host, listener.listen_port)
        if endpoint in endpoints:
            raise ValueError(f"duplicate listener endpoint: {endpoint}")
        endpoints.add(endpoint)
        listeners.append(listener)
    return listeners


async def copy_stream(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    *,
    metadata: MetadataLog,
    listener: Listener,
    connection_id: str,
    direction: str,
) -> int:
    total = 0
    try:
        while chunk := await reader.read(READ_SIZE):
            total += len(chunk)
            await metadata.write(
                {
                    "event": "flow",
                    "connection_id": connection_id,
                    "listener": listener.name,
                    "source": listener.source_label if direction == "outbound" else listener.target_label,
                    "target": listener.target_label if direction == "outbound" else listener.source_label,
                    "direction": direction,
                    "bytes": len(chunk),
                }
            )
            writer.write(chunk)
            await writer.drain()
    finally:
        try:
            writer.write_eof()
        except (AttributeError, OSError, RuntimeError):
            pass
    return total


async def handle_connection(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    *,
    listener: Listener,
    metadata: MetadataLog,
) -> None:
    connection_id = uuid.uuid4().hex
    peer = client_writer.get_extra_info("peername")
    opened = time.monotonic()
    await metadata.write(
        {
            "event": "connection_open",
            "connection_id": connection_id,
            "listener": listener.name,
            "peer": str(peer),
            "source": listener.source_label,
            "target": listener.target_label,
        }
    )
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(
            listener.upstream_host, listener.upstream_port
        )
        outbound, inbound = await asyncio.gather(
            copy_stream(
                client_reader,
                upstream_writer,
                metadata=metadata,
                listener=listener,
                connection_id=connection_id,
                direction="outbound",
            ),
            copy_stream(
                upstream_reader,
                client_writer,
                metadata=metadata,
                listener=listener,
                connection_id=connection_id,
                direction="inbound",
            ),
        )
        await metadata.write(
            {
                "event": "connection_close",
                "connection_id": connection_id,
                "listener": listener.name,
                "outbound_bytes": outbound,
                "inbound_bytes": inbound,
                "duration_ms": round((time.monotonic() - opened) * 1000, 3),
            }
        )
    except Exception as exc:
        await metadata.write(
            {
                "event": "connection_error",
                "connection_id": connection_id,
                "listener": listener.name,
                "error_type": type(exc).__name__,
            }
        )
    finally:
        client_writer.close()
        await client_writer.wait_closed()


async def run(
    config_path: Path,
    output_path: Path,
    *,
    max_log_bytes: int,
    log_backups: int,
) -> None:
    if not 1024 * 1024 <= max_log_bytes <= 4 * 1024 * 1024 * 1024:
        raise ValueError("max-log-bytes must be between 1 MiB and 4 GiB")
    if not 1 <= log_backups <= 16:
        raise ValueError("log-backups must be between 1 and 16")
    listeners = load_config(config_path)
    metadata = MetadataLog(
        output_path,
        max_bytes=max_log_bytes,
        backups=log_backups,
    )
    servers = []
    try:
        for listener in listeners:
            server = await asyncio.start_server(
                lambda reader, writer, item=listener: handle_connection(
                    reader, writer, listener=item, metadata=metadata
                ),
                listener.listen_host,
                listener.listen_port,
            )
            servers.append(server)
            await metadata.write(
                {
                    "event": "listener_ready",
                    "listener": listener.name,
                    "source": listener.source_label,
                    "target": listener.target_label,
                    "listen_port": listener.listen_port,
                    "upstream_port": listener.upstream_port,
                }
            )
        await asyncio.gather(*(server.serve_forever() for server in servers))
    finally:
        for server in servers:
            server.close()
        await asyncio.gather(*(server.wait_closed() for server in servers), return_exceptions=True)
        metadata.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="OUO metadata-only L4 traffic observer")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-log-bytes", type=int, default=128 * 1024 * 1024)
    parser.add_argument("--log-backups", type=int, default=3)
    args = parser.parse_args()
    asyncio.run(
        run(
            args.config,
            args.output,
            max_log_bytes=args.max_log_bytes,
            log_backups=args.log_backups,
        )
    )


if __name__ == "__main__":
    main()
