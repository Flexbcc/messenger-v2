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


RelayMode = Literal["http", "websocket-preferred", "websocket-required"]


class RelayTransportAdapter:
    def __init__(
        self,
        *,
        signing_key: SigningKey,
        node_id: str,
        mode: RelayMode,
        timeout_seconds: float = 10.0,
    ) -> None:
        if mode not in {"http", "websocket-preferred", "websocket-required"}:
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
        self._http = httpx.AsyncClient(
            timeout=timeout_seconds,
            follow_redirects=False,
            trust_env=False,
        )

    async def forward(self, relay_url: str, payload: dict[str, Any]) -> dict[str, Any]:
        websocket_error: Exception | None = None
        if self.mode != "http":
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
            if websocket_error is not None:
                raise RelayTransportError(
                    f"WebSocket failed ({websocket_error}); HTTP fallback failed ({exc})"
                ) from exc
            raise RelayTransportError(f"Relay HTTP transport failed: {exc}") from exc

    async def forward_many(
        self, relay_url: str, payloads: list[dict[str, Any]]
    ) -> list[dict[str, Any]]:
        if self.mode != "http":
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
        await self._websocket.close()
        await self._http.aclose()
