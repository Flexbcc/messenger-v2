from unittest.mock import AsyncMock

import pytest

from shared.security.config import HDR_NODE_ID
from shared.security.http_client import federation_delete, federation_get, federation_post


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("method", "call"),
    [
        ("post", federation_post),
        ("get", federation_get),
        ("delete", federation_delete),
    ],
)
async def test_legacy_client_identifies_registered_origin(monkeypatch, method, call):
    monkeypatch.setattr("shared.security.http_client.INTERNAL_SECURITY_MODE", "legacy")
    client = AsyncMock()

    kwargs = {
        "path": "/internal/test",
        "signing_key": None,
        "node_id": "relay-pve2",
    }
    if method == "post":
        kwargs["payload"] = {"ciphertext": "opaque"}

    await call(client, "http://home-b/internal/test", **kwargs)

    request = getattr(client, method)
    headers = request.await_args.kwargs["headers"]
    assert headers[HDR_NODE_ID] == "relay-pve2"
