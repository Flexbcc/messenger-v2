import json
from typing import Any, Optional

import httpx

from shared.security.config import HDR_NODE_ID, INTERNAL_SECURITY_MODE
from shared.security.federation_auth import sign_federation_request
from shared.security.keys import SigningKey


def _mode_legacy() -> bool:
    return INTERNAL_SECURITY_MODE in ("legacy", "off", "")


def _federation_headers(
    *,
    method: str,
    path: str,
    body: bytes,
    signing_key: Optional[SigningKey],
    node_id: str,
) -> dict[str, str]:
    if not node_id:
        raise ValueError("federation request requires a node id")
    if _mode_legacy():
        return {HDR_NODE_ID: node_id}
    if signing_key is None:
        raise RuntimeError("signed federation request requires a signing key")
    return sign_federation_request(
        signing_key=signing_key,
        node_id=node_id,
        method=method,
        path=path,
        body=body,
    )


async def federation_post(
    client: httpx.AsyncClient,
    url: str,
    *,
    path: str,
    payload: dict[str, Any],
    signing_key: Optional[SigningKey],
    node_id: str,
) -> httpx.Response:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    headers = _federation_headers(
        method="POST",
        path=path,
        body=body,
        signing_key=signing_key,
        node_id=node_id,
    )
    headers["Content-Type"] = "application/json"
    return await client.post(url, content=body, headers=headers)


async def federation_get(
    client: httpx.AsyncClient,
    url: str,
    *,
    path: str,
    signing_key: Optional[SigningKey],
    node_id: str,
) -> httpx.Response:
    body = b""
    headers = _federation_headers(
        method="GET",
        path=path,
        body=body,
        signing_key=signing_key,
        node_id=node_id,
    )
    return await client.get(url, headers=headers)


async def federation_get_stream(
    client: httpx.AsyncClient,
    url: str,
    *,
    path: str,
    signing_key: Optional[SigningKey],
    node_id: str,
) -> httpx.Response:
    """Start a signed GET without buffering an untrusted response body.

    The caller owns the returned response and must close it.
    """
    body = b""
    headers = _federation_headers(
        method="GET",
        path=path,
        body=body,
        signing_key=signing_key,
        node_id=node_id,
    )
    request = client.build_request("GET", url, headers=headers)
    return await client.send(request, stream=True)


async def federation_delete(
    client: httpx.AsyncClient,
    url: str,
    *,
    path: str,
    signing_key: Optional[SigningKey],
    node_id: str,
) -> httpx.Response:
    body = b""
    headers = _federation_headers(
        method="DELETE",
        path=path,
        body=body,
        signing_key=signing_key,
        node_id=node_id,
    )
    return await client.delete(url, headers=headers)
