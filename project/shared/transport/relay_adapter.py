"""Transport-agnostic client facade for OUO Basic Relay.

The upper relay protocol submits the same object regardless of whether the
current link uses signed HTTP or a persistent binary WebSocket session.
"""

from __future__ import annotations

from typing import Any, Literal

import httpx

from shared.security.http_client import federation_post
from shared.security.keys import SigningKey
from shared.transport.ws_relay_client import RelayTransportError, RelayWebSocketClient


RelayMode = Literal[
    "http", "websocket-preferred", "websocket-required",
    "quic-preferred", "quic-required",
]


class RelayTransportAdapter:
    def __init__(
        self,
        *,
        signing_key: SigningKey,
        node_id: str,
        mode: RelayMode,
        timeout_seconds: float = 10.0,
        quic_ca_file: str | None = None,
    ) -> None:
        if mode not in {
            "http", "websocket-preferred", "websocket-required",
            "quic-preferred", "quic-required",
        }:
            raise ValueError("unsupported Relay transport mode")
        self.signing_key = signing_key
        self.node_id = node_id
        self.mode = mode
        self.timeout_seconds = timeout_seconds
        self._websocket = RelayWebSocketClient(
            signing_key=signing_key,
            node_id=node_id,
            timeout_seconds=timeout_seconds,
        )
        self._quic = None
        if mode.startswith("quic-"):
            from shared.transport.quic_relay_client import RelayQuicClient
            self._quic = RelayQuicClient(
                signing_key=signing_key,
                node_id=node_id,
                timeout_seconds=timeout_seconds,
                ca_file=quic_ca_file,
            )
        self._http = httpx.AsyncClient(
            timeout=timeout_seconds,
            follow_redirects=False,
            trust_env=False,
        )

    async def forward(self, relay_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        quic_error: Exception | None = None
        if self._quic is not None:
            try:
                return await self._quic.forward(relay_url, payload)
            except Exception as exc:
                quic_error = exc
                if self.mode == "quic-required":
                    raise RelayTransportError(f"QUIC Relay transport failed: {exc}") from exc
        websocket_error: Exception | None = None
        if self.mode.startswith("websocket-"):
            try:
                return await self._websocket.forward(relay_url, payload)
            except RelayTransportError as exc:
                websocket_error = exc
                if self.mode == "websocket-required":
                    raise
        try:
            response = await federation_post(
                self._http,
                f"{relay_url.rstrip('/')}/relay/forward",
                path="/relay/forward",
                payload=payload,
                signing_key=self.signing_key,
                node_id=self.node_id,
            )
            response.raise_for_status()
            result = response.json()
            if not isinstance(result, dict):
                raise RelayTransportError("Relay HTTP response is not an object")
            return result
        except (httpx.HTTPError, ValueError) as exc:
            if quic_error is not None:
                raise RelayTransportError(
                    f"QUIC failed ({quic_error}); HTTP fallback failed ({exc})"
                ) from exc
            if websocket_error is not None:
                raise RelayTransportError(
                    f"WebSocket failed ({websocket_error}); HTTP fallback failed ({exc})"
                ) from exc
            raise RelayTransportError(f"Relay HTTP transport failed: {exc}") from exc

    async def forward_many(
        self, relay_url: str, payloads: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        if self._quic is not None:
            try:
                return await self._quic.forward_many(relay_url, payloads)
            except Exception:
                if self.mode == "quic-required":
                    raise RelayTransportError("QUIC Relay batch transport failed")
        if self.mode.startswith("websocket-"):
            try:
                return await self._websocket.forward_many(relay_url, payloads)
            except RelayTransportError:
                if self.mode == "websocket-required":
                    raise
        # HTTP is deliberately a compatibility/control fallback. Keep request
        # ordering deterministic when the persistent batch link is unavailable.
        results = []
        for payload in payloads:
            results.append(await self.forward(relay_url, payload))
        return results

    async def close(self) -> None:
        if self._quic is not None:
            await self._quic.close()
        await self._websocket.close()
        await self._http.aclose()
