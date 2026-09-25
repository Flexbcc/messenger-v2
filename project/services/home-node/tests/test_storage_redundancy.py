"""Home-side Storage replica selection, write quorum and deduplicated drain."""

import json
from unittest.mock import AsyncMock

import httpx
import pytest

from app import federation
from app import storage_buffer_client


class _DummyClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None


class _Response:
    def __init__(self, *, status_code=200, body=None):
        self.status_code = status_code
        self._body = body or {}
        self.content = json.dumps(self._body).encode()

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise httpx.HTTPStatusError(
                "storage failure",
                request=httpx.Request("POST", "http://storage.invalid/buffer"),
                response=httpx.Response(self.status_code),
            )


@pytest.mark.asyncio
async def test_storage_replica_selection_is_bounded_and_deduplicated(monkeypatch):
    monkeypatch.setattr(federation.settings, "resource_policy", "federated")
    monkeypatch.setattr(federation.settings, "signed_peer_selection_mode", "off")
    monkeypatch.setattr(federation.settings, "storage_node_url", "http://storage-a")
    monkeypatch.setattr(
        federation.settings,
        "storage_node_urls",
        ("http://storage-a", "http://storage-c"),
    )
    monkeypatch.setattr(federation.settings, "storage_replication_factor", 3)
    monkeypatch.setattr(
        federation,
        "_list_discovery_nodes",
        AsyncMock(return_value=["http://storage-b", "http://storage-a"]),
    )
    monkeypatch.setattr(
        federation,
        "_rank_reachable",
        AsyncMock(return_value=["http://storage-a", "http://storage-b"]),
    )

    assert await federation._resolve_storage_urls() == [
        "http://storage-a",
        "http://storage-b",
        "http://storage-c",
    ]


@pytest.mark.asyncio
async def test_storage_write_succeeds_when_quorum_is_reached(monkeypatch):
    monkeypatch.setattr(
        federation,
        "_resolve_storage_urls",
        AsyncMock(return_value=["http://storage-a", "http://storage-b"]),
    )
    monkeypatch.setattr(federation.settings, "storage_write_quorum", 1)
    monkeypatch.setattr(
        storage_buffer_client.httpx, "AsyncClient", lambda **_kwargs: _DummyClient()
    )
    calls = []

    async def post(_client, url, **_kwargs):
        calls.append(url)
        if url.startswith("http://storage-b"):
            raise httpx.ConnectError("offline")
        return _Response()

    monkeypatch.setattr(storage_buffer_client, "federation_post", post)
    await federation.buffer_for_offline_user(
        "user-b", {"packet_id": "packet-1", "ciphertext": "opaque"}
    )
    assert set(calls) == {
        "http://storage-a/buffer",
        "http://storage-b/buffer",
    }


@pytest.mark.asyncio
async def test_storage_write_fails_closed_below_quorum(monkeypatch):
    monkeypatch.setattr(
        federation,
        "_resolve_storage_urls",
        AsyncMock(return_value=["http://storage-a", "http://storage-b"]),
    )
    monkeypatch.setattr(federation.settings, "storage_write_quorum", 2)
    monkeypatch.setattr(
        storage_buffer_client.httpx, "AsyncClient", lambda **_kwargs: _DummyClient()
    )

    async def post(_client, url, **_kwargs):
        if url.startswith("http://storage-b"):
            raise httpx.ConnectError("offline")
        return _Response()

    monkeypatch.setattr(storage_buffer_client, "federation_post", post)
    with pytest.raises(RuntimeError, match="write quorum"):
        await federation.buffer_for_offline_user(
            "user-b", {"packet_id": "packet-1", "ciphertext": "opaque"}
        )


@pytest.mark.asyncio
async def test_replicated_drain_delivers_once_and_keeps_copies_until_ack(monkeypatch):
    monkeypatch.setattr(
        federation,
        "_resolve_storage_urls",
        AsyncMock(return_value=["http://storage-a", "http://storage-b"]),
    )
    monkeypatch.setattr(
        storage_buffer_client.httpx, "AsyncClient", lambda **_kwargs: _DummyClient()
    )
    envelope = {"packet_id": "packet-1", "ciphertext": "opaque"}

    async def get(_client, url, **_kwargs):
        entry_id = "entry-a" if url.startswith("http://storage-a") else "entry-b"
        return _Response(body={"envelopes": [{"id": entry_id, "envelope": envelope}]})

    deliver = AsyncMock(return_value=True)
    monkeypatch.setattr(storage_buffer_client, "federation_get", get)

    await federation.drain_buffer("user-b", deliver)

    deliver.assert_awaited_once_with(envelope)
