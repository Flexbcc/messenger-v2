"""Persistent Home/Relay WebSocket adapter for OUO Basic Transport."""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from websockets.asyncio.client import connect as websocket_connect

from shared.security.federation_auth import sign_federation_request
from shared.security.keys import SigningKey
from shared.transport.binary_batch import BatchDecodeError, decode_batch, encode_batch
from shared.transport.link_cell import build_link_cell


class RelayTransportError(RuntimeError):
    """The persistent relay link failed or returned a rejected cell."""


def relay_websocket_url(relay_url: str) -> str:
    parsed = urlsplit(relay_url)
    scheme = {"http": "ws", "https": "wss"}.get(parsed.scheme)
    if scheme is None or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("relay URL must be an absolute http(s) URL without credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("relay URL must not contain query or fragment")
    base_path = parsed.path.rstrip("/")
    return urlunsplit((scheme, parsed.netloc, f"{base_path}/relay/ws", "", ""))


@dataclass
class _RelayLink:
    websocket: Any
    sequence: int = 0
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class RelayWebSocketClient:
    """Keeps one authenticated, ordered binary-batch link per Relay URL.

    A reconnect receives a fresh signed connection nonce and restarts its local
    sequence at one. The Relay persists the highest sequence for each nonce, so
    replay/reorder remains fail-closed across Relay process restarts.
    """

    def __init__(
        self,
        *,
        signing_key: SigningKey,
        node_id: str,
        timeout_seconds: float = 10.0,
    ) -> None:
        self.signing_key = signing_key
        self.node_id = node_id
        self.timeout_seconds = timeout_seconds
        self._links: dict[str, _RelayLink] = {}
        self._links_lock = asyncio.Lock()

    async def _connect(self, relay_url: str) -> _RelayLink:
        headers = sign_federation_request(
            signing_key=self.signing_key,
            node_id=self.node_id,
            method="GET",
            path="/relay/ws",
            body=b"",
        )
        websocket = await websocket_connect(
            relay_websocket_url(relay_url),
            additional_headers=headers,
            open_timeout=self.timeout_seconds,
            close_timeout=min(self.timeout_seconds, 5.0),
            max_size=1024 * 1024,
        )
        return _RelayLink(websocket=websocket)

    async def _get_link(self, relay_url: str) -> _RelayLink:
        async with self._links_lock:
            link = self._links.get(relay_url)
            if link is None:
                link = await self._connect(relay_url)
                self._links[relay_url] = link
            return link

    async def _discard(self, relay_url: str, link: _RelayLink) -> None:
        async with self._links_lock:
            if self._links.get(relay_url) is link:
                self._links.pop(relay_url, None)
        try:
            await link.websocket.close()
        except Exception:
            pass

    async def forward_many(
        self, relay_url: str, payloads: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        if not isinstance(payloads, list) or not payloads:
            raise ValueError("Relay payload batch must be a non-empty list")
        if any(not isinstance(payload, dict) for payload in payloads):
            raise ValueError("Relay payloads must be objects")
        bodies = [
            json.dumps(
                build_link_cell(payload), separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            for payload in payloads
        ]
        last_error: Exception | None = None
        for _attempt in range(2):
            link = await self._get_link(relay_url)
            try:
                async with link.lock:
                    link.sequence += 1
                    sequence = link.sequence
                    await asyncio.wait_for(
                        link.websocket.send(encode_batch(sequence=sequence, cells=bodies)),
                        timeout=self.timeout_seconds,
                    )
                    raw = await asyncio.wait_for(
                        link.websocket.recv(), timeout=self.timeout_seconds
                    )
                    if not isinstance(raw, bytes):
                        raise RelayTransportError("Relay returned a non-binary frame")
                    reply = decode_batch(raw)
                    if reply.sequence != sequence or len(reply.cells) != len(bodies):
                        raise RelayTransportError("Relay returned a mismatched batch")
                    results = []
                    for cell in reply.cells:
                        response = json.loads(cell)
                        if not isinstance(response, dict):
                            raise RelayTransportError("Relay returned an invalid response object")
                        if response.get("ok") is not True:
                            raise RelayTransportError(
                                f"Relay rejected cell ({response.get('status', 500)}): "
                                f"{response.get('detail', 'unknown error')}"
                            )
                        result = response.get("result")
                        if not isinstance(result, dict):
                            raise RelayTransportError("Relay response has no result object")
                        results.append(result)
                    return results
            except (
                RelayTransportError,
                BatchDecodeError,
                json.JSONDecodeError,
                UnicodeDecodeError,
            ) as exc:
                await self._discard(relay_url, link)
                raise RelayTransportError(str(exc)) from exc
            except Exception as exc:
                last_error = exc
                await self._discard(relay_url, link)
        raise RelayTransportError(f"Relay WebSocket link failed: {last_error}") from last_error

    async def forward(self, relay_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        return (await self.forward_many(relay_url, [payload]))[0]

    async def close(self) -> None:
        async with self._links_lock:
            links = list(self._links.values())
            self._links.clear()
        for link in links:
            try:
                await link.websocket.close()
            except Exception:
                pass
