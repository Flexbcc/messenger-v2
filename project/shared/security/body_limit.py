"""ASGI request-body bound applied before FastAPI parses federation JSON."""

from __future__ import annotations

import json
from collections.abc import Iterable

from shared.security.config import (
    FEDERATION_MAX_BODY_BYTES,
    HDR_NODE_ID,
    HDR_NONCE,
    HDR_SIGNATURE,
    HDR_TIMESTAMP,
    INTERNAL_SECURITY_MODE,
)
from shared.security.metrics import metrics


class FederationBodyTooLarge(Exception):
    pass


class FederationBodyLimitMiddleware:
    def __init__(self, app, *, path_prefixes: Iterable[str]):
        self.app = app
        self.path_prefixes = tuple(path_prefixes)
        if not self.path_prefixes or any(
            not isinstance(prefix, str) or not prefix.startswith("/")
            for prefix in self.path_prefixes
        ):
            raise ValueError("federation body-limit prefixes must be absolute paths")

    def _protected(self, path: str) -> bool:
        return any(
            path == prefix.rstrip("/")
            or path.startswith(prefix if prefix.endswith("/") else prefix + "/")
            for prefix in self.path_prefixes
        )

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http" or not self._protected(scope.get("path", "")):
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        if INTERNAL_SECURITY_MODE not in {"legacy", "off", ""}:
            required = {
                HDR_NODE_ID.lower().encode("ascii"): (1, 256),
                HDR_TIMESTAMP.lower().encode("ascii"): (1, 64),
                HDR_NONCE.lower().encode("ascii"): (36, 36),
                HDR_SIGNATURE.lower().encode("ascii"): (88, 88),
            }
            if any(
                name not in headers or not minimum <= len(headers[name]) <= maximum
                for name, (minimum, maximum) in required.items()
            ):
                await self._reject(send, 401, "Missing or malformed federation auth headers")
                return
        declared = headers.get(b"content-length")
        if declared is not None:
            try:
                length = int(declared)
            except (TypeError, ValueError):
                await self._reject(send, 400, "Invalid Content-Length")
                return
            if length < 0:
                await self._reject(send, 400, "Invalid Content-Length")
                return
            if length > FEDERATION_MAX_BODY_BYTES:
                await self._reject(send, 413, "Federation request body exceeds limit")
                return

        total = 0

        async def bounded_receive():
            nonlocal total
            message = await receive()
            if message.get("type") == "http.request":
                total += len(message.get("body", b""))
                if total > FEDERATION_MAX_BODY_BYTES:
                    raise FederationBodyTooLarge
            return message

        try:
            await self.app(scope, bounded_receive, send)
        except FederationBodyTooLarge:
            await self._reject(send, 413, "Federation request body exceeds limit")

    @staticmethod
    async def _reject(send, status: int, detail: str) -> None:
        metrics().admission_rejected += 1
        body = json.dumps({"detail": detail}, separators=(",", ":")).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})
