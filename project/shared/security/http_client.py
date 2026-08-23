import json
from typing import Any, Optional

import httpx

from shared.security.config import HDR_NODE_ID, INTERNAL_SECURITY_MODE
from shared.security.federation_auth import sign_federation_request
from shared.security.keys import SigningKey


def _mode_legacy() -> bool:
    return INTERNAL_SECURITY_MODE in ("legacy", "off", "")


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
    headers = {"Content-Type": "application/json"}
    if _mode_legacy():
        headers[HDR_NODE_ID] = node_id
    elif signing_key is not None:
        headers.update(
            sign_federation_request(
                signing_key=signing_key,
                node_id=node_id,
                method="POST",
                path=path,
                body=body,
            )
        )
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
    headers: dict[str, str] = {}
    if _mode_legacy():
        headers[HDR_NODE_ID] = node_id
    elif signing_key is not None:
        headers.update(
            sign_federation_request(
                signing_key=signing_key,
                node_id=node_id,
                method="GET",
                path=path,
                body=body,
            )
        )
    return await client.get(url, headers=headers)


async def federation_delete(
    client: httpx.AsyncClient,
    url: str,
    *,
    path: str,
    signing_key: Optional[SigningKey],
    node_id: str,
) -> httpx.Response:
    body = b""
    headers: dict[str, str] = {}
    if _mode_legacy():
        headers[HDR_NODE_ID] = node_id
    elif signing_key is not None:
        headers.update(
            sign_federation_request(
                signing_key=signing_key,
                node_id=node_id,
                method="DELETE",
                path=path,
                body=body,
            )
        )
    return await client.delete(url, headers=headers)
