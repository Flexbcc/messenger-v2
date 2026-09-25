"""ASGI request-body bounds applied before FastAPI parses request payloads."""

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


class RequestBodyTooLarge(Exception):
    pass


class RequestBodyLimitMiddleware:
    def __init__(
        self,
        app,
        *,
        path_prefixes: Iterable[str],
        max_body_bytes: int = FEDERATION_MAX_BODY_BYTES,
        require_federation_headers: bool = True,
    ):
        self.app = app
        self.path_prefixes = tuple(path_prefixes)
        self.max_body_bytes = max_body_bytes
        self.require_federation_headers = require_federation_headers
        if not self.path_prefixes or any(
            not isinstance(prefix, str) or not prefix.startswith("/")
            for prefix in self.path_prefixes
        ):
            raise ValueError("federation body-limit prefixes must be absolute paths")
        if not isinstance(max_body_bytes, int) or max_body_bytes < 1:
            raise ValueError("request body limit must be a positive integer")

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
        if (
            self.require_federation_headers
            and INTERNAL_SECURITY_MODE not in {"legacy", "off", ""}
        ):
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
            if length > self.max_body_bytes:
                await self._reject(send, 413, "Request body exceeds limit")
                return

        total = 0

        async def bounded_receive():
            nonlocal total
            message = await receive()
            if message.get("type") == "http.request":
                total += len(message.get("body", b""))
                if total > self.max_body_bytes:
                    raise RequestBodyTooLarge
            return message

        try:
            await self.app(scope, bounded_receive, send)
        except RequestBodyTooLarge:
            await self._reject(send, 413, "Request body exceeds limit")

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


# Compatibility name for existing service imports. Defaults preserve the
# federation-header requirement and shared federation body limit.
FederationBodyLimitMiddleware = RequestBodyLimitMiddleware
