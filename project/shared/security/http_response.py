"""Bounded HTTP response readers for untrusted service endpoints."""

import json
from typing import Any, Mapping

import httpx


async def get_bounded_json(
    client: httpx.AsyncClient,
    url: str,
    *,
    max_bytes: int,
    params: Mapping[str, str] | None = None,
) -> tuple[int, Any]:
    if max_bytes <= 0:
        raise ValueError("max_bytes must be positive")
    async with client.stream("GET", url, params=params) as response:
        declared = response.headers.get("content-length")
        if declared is not None:
            try:
                declared_size = int(declared)
            except ValueError as exc:
                raise ValueError("upstream returned an invalid content length") from exc
            if declared_size < 0 or declared_size > max_bytes:
                raise ValueError("upstream JSON response is too large")
        body = bytearray()
        async for chunk in response.aiter_bytes():
            if len(body) + len(chunk) > max_bytes:
                raise ValueError("upstream JSON response is too large")
            body.extend(chunk)
        status_code = response.status_code
    return status_code, json.loads(body)


def parse_bounded_json_response(response: httpx.Response, *, max_bytes: int) -> Any:
    """Decode an already-buffered response while enforcing a small body cap."""
    if max_bytes <= 0:
        raise ValueError("max_bytes must be positive")
    body = response.content
    if len(body) > max_bytes:
        raise ValueError("upstream JSON response is too large")
    return json.loads(body)
