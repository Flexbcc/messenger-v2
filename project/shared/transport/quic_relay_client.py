"""Persistent HTTP/3 adapter for the OUO Relay data plane."""

from __future__ import annotations

import asyncio
import json
import ssl
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Deque
from urllib.parse import urlsplit

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, H3Event, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent

from shared.security.federation_auth import sign_federation_request
from shared.security.keys import SigningKey


MAX_RESPONSE_BYTES = 1024 * 1024


class RelayQuicError(RuntimeError):
    pass


class _Http3Protocol(QuicConnectionProtocol):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._events: dict[int, Deque[H3Event]] = {}
        self._waiters: dict[int, asyncio.Future[Deque[H3Event]]] = {}

    async def post(
        self, *, authority: str, path: str, headers: dict[str, str], body: bytes
    ) -> Deque[H3Event]:
        stream_id = self._quic.get_next_available_stream_id()
        self._http.send_headers(
            stream_id=stream_id,
            headers=[
                (b":method", b"POST"),
                (b":scheme", b"https"),
                (b":authority", authority.encode("ascii")),
                (b":path", path.encode("ascii")),
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
            ]
            + [
                (name.lower().encode("ascii"), value.encode("ascii"))
                for name, value in headers.items()
            ],
            end_stream=False,
        )
        self._http.send_data(stream_id=stream_id, data=body, end_stream=True)
        waiter = asyncio.get_running_loop().create_future()
        self._events[stream_id] = deque()
        self._waiters[stream_id] = waiter
        self.transmit()
        return await asyncio.shield(waiter)

    def quic_event_received(self, event: QuicEvent) -> None:
        for http_event in self._http.handle_event(event):
            if not isinstance(http_event, (HeadersReceived, DataReceived)):
                continue
            stream_id = http_event.stream_id
            events = self._events.get(stream_id)
            if events is None:
                continue
            events.append(http_event)
            if http_event.stream_ended:
                waiter = self._waiters.pop(stream_id, None)
                completed = self._events.pop(stream_id, deque())
                if waiter is not None and not waiter.done():
                    waiter.set_result(completed)


@dataclass
class _QuicLink:
    context: Any
    protocol: _Http3Protocol
    authority: str
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class RelayQuicClient:
    """Keeps one certificate-validated QUIC connection per Relay origin."""

    def __init__(
        self,
        *,
        signing_key: SigningKey,
        node_id: str,
        timeout_seconds: float = 10.0,
        ca_file: str | None = None,
    ) -> None:
        if not 0.1 <= timeout_seconds <= 60:
            raise ValueError("invalid QUIC timeout")
        self.signing_key = signing_key
        self.node_id = node_id
        self.timeout_seconds = timeout_seconds
        self.ca_file = ca_file
        self._links: dict[str, _QuicLink] = {}
        self._links_lock = asyncio.Lock()

    async def _connect(self, relay_url: str) -> _QuicLink:
        parsed = urlsplit(relay_url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
        ):
            raise RelayQuicError("QUIC Relay URL must be an absolute https URL")
        port = parsed.port or 443
        authority = parsed.netloc
        configuration = QuicConfiguration(
            is_client=True,
            alpn_protocols=H3_ALPN,
            server_name=parsed.hostname,
            verify_mode=ssl.CERT_REQUIRED,
        )
        if self.ca_file:
            configuration.load_verify_locations(self.ca_file)
        context = connect(
            parsed.hostname,
            port,
            configuration=configuration,
            create_protocol=_Http3Protocol,
            wait_connected=True,
        )
        try:
            protocol = await asyncio.wait_for(
                context.__aenter__(), timeout=self.timeout_seconds
            )
        except Exception:
            await context.__aexit__(None, None, None)
            raise
        return _QuicLink(context=context, protocol=protocol, authority=authority)

    async def _get_link(self, relay_url: str) -> _QuicLink:
        async with self._links_lock:
            link = self._links.get(relay_url)
            if link is None:
                link = await self._connect(relay_url)
                self._links[relay_url] = link
            return link

    async def _discard(self, relay_url: str, link: _QuicLink) -> None:
        async with self._links_lock:
            if self._links.get(relay_url) is link:
                self._links.pop(relay_url, None)
        try:
            await link.context.__aexit__(None, None, None)
        except Exception:
            pass

    async def forward(self, relay_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise ValueError("Relay payload must be an object")
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        headers = sign_federation_request(
            signing_key=self.signing_key,
            node_id=self.node_id,
            method="POST",
            path="/relay/forward",
            body=body,
        )
        last_error: Exception | None = None
        for _attempt in range(2):
            link = await self._get_link(relay_url)
            try:
                async with link.lock:
                    events = await asyncio.wait_for(
                        link.protocol.post(
                            authority=link.authority,
                            path="/relay/forward",
                            headers=headers,
                            body=body,
                        ),
                        timeout=self.timeout_seconds,
                    )
                return _decode_response(events)
            except Exception as exc:
                last_error = exc
                await self._discard(relay_url, link)
        raise RelayQuicError(f"QUIC Relay request failed: {last_error}") from last_error

    async def forward_many(
        self, relay_url: str, payloads: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        if not payloads:
            raise ValueError("Relay payload batch must be non-empty")
        # Independent HTTP/3 streams avoid cross-request head-of-line blocking.
        return list(await asyncio.gather(*(self.forward(relay_url, item) for item in payloads)))

    async def close(self) -> None:
        async with self._links_lock:
            links = list(self._links.values())
            self._links.clear()
        await asyncio.gather(
            *(link.context.__aexit__(None, None, None) for link in links),
            return_exceptions=True,
        )


def _decode_response(events: Deque[H3Event]) -> dict[str, Any]:
    status: int | None = None
    body = bytearray()
    for event in events:
        if isinstance(event, HeadersReceived):
            for name, value in event.headers:
                if name == b":status":
                    try:
                        status = int(value)
                    except ValueError as exc:
                        raise RelayQuicError("invalid HTTP/3 status") from exc
        elif isinstance(event, DataReceived):
            body.extend(event.data)
            if len(body) > MAX_RESPONSE_BYTES:
                raise RelayQuicError("HTTP/3 response exceeds limit")
    if status is None or not 200 <= status < 300:
        raise RelayQuicError(f"Relay HTTP/3 status {status or 0}")
    try:
        result = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RelayQuicError("Relay returned invalid HTTP/3 JSON") from exc
    if not isinstance(result, dict):
        raise RelayQuicError("Relay HTTP/3 response is not an object")
    return result
