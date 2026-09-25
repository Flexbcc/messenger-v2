"""Tests for the Post-R5 user->home resolve cache and outage fallback."""
from unittest.mock import patch

import httpx
import pytest

from app import federation
from app.federation import _cache_lookup, _cache_store
from shared.transport.ws_relay_client import RelayTransportError


def test_cache_store_then_lookup_hits_before_expiry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=159.9) == "http://home-a"


def test_cache_lookup_misses_at_or_after_expiry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=160.0) is None


def test_cache_lookup_misses_when_absent():
    cache: dict[str, tuple[str, float]] = {}
    assert _cache_lookup(cache, "unknown", now=0.0) is None


def test_cache_store_with_zero_or_negative_ttl_disables_caching():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=0)
    assert cache == {}
    assert _cache_lookup(cache, "u1", now=100.0) is None


def test_cache_store_overwrites_previous_entry():
    cache: dict[str, tuple[str, float]] = {}
    _cache_store(cache, "u1", "http://home-a", now=100.0, ttl_seconds=60)
    _cache_store(cache, "u1", "http://home-b", now=110.0, ttl_seconds=60)
    assert _cache_lookup(cache, "u1", now=111.0) == "http://home-b"


@pytest.mark.asyncio
async def test_discovery_outage_uses_bounded_last_known_route(monkeypatch):
    federation._home_node_cache.clear()
    federation._home_node_stale_cache.clear()
    _cache_store(
        federation._home_node_stale_cache,
        "user-b",
        "http://home-b:8001",
        now=100.0,
        ttl_seconds=3600,
    )

    class FailingClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, _url):
            raise httpx.ConnectError("discovery unavailable")

    monkeypatch.setattr(federation.httpx, "AsyncClient", lambda **_kwargs: FailingClient())
    with patch.object(federation.time, "monotonic", return_value=101.0):
        assert await federation.resolve_home_node("user-b") == "http://home-b:8001"


@pytest.mark.asyncio
async def test_expired_last_known_route_is_not_used(monkeypatch):
    federation._home_node_cache.clear()
    federation._home_node_stale_cache.clear()
    _cache_store(
        federation._home_node_stale_cache,
        "user-b",
        "http://home-b:8001",
        now=100.0,
        ttl_seconds=1,
    )

    class FailingClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, _url):
            raise httpx.ConnectError("discovery unavailable")

    monkeypatch.setattr(federation.httpx, "AsyncClient", lambda **_kwargs: FailingClient())
    with patch.object(federation.time, "monotonic", return_value=102.0):
        assert await federation.resolve_home_node("user-b") is None


class _DummyAsyncClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None


class _OkResponse:
    def raise_for_status(self):
        return None


def _relay_test_payloads():
    return (
        {
            "packet_id": "packet-1",
            "sender_user_id": "user-a",
            "ciphertext": "opaque",
        },
        {
            "conversation_id": "conversation-1",
            "participant_user_ids": ["user-a", "user-b"],
        },
    )


@pytest.mark.asyncio
async def test_home_prefers_persistent_websocket_relay(monkeypatch):
    envelope, conversation_meta = _relay_test_payloads()
    calls = []

    class WsClient:
        async def forward(self, relay_url, payload):
            calls.append((relay_url, payload))
            return {"status": "forwarded"}

    async def direct_fails(*_args, **_kwargs):
        raise httpx.ConnectError("direct unavailable")

    monkeypatch.setattr(federation, "_get_target_curve_public_key", lambda *_args: _none())
    monkeypatch.setattr(federation, "_reachable_relays", lambda: _value(["http://relay-a"]))
    monkeypatch.setattr(federation, "_get_relay_transport", lambda: WsClient())
    monkeypatch.setattr(federation, "federation_post", direct_fails)
    monkeypatch.setattr(federation.httpx, "AsyncClient", lambda **_kwargs: _DummyAsyncClient())
    monkeypatch.setattr(federation.settings, "relay_transport_mode", "websocket-preferred")

    await federation.deliver_to_remote_home_node(
        "http://home-b", envelope, conversation_meta
    )
    assert len(calls) == 1
    assert calls[0][0] == "http://relay-a"


@pytest.mark.asyncio
async def test_home_websocket_preferred_falls_back_to_http(monkeypatch):
    envelope, conversation_meta = _relay_test_payloads()
    http_paths = []

    class WsClient:
        async def forward(self, relay_url, payload):
            # RelayTransportAdapter owns WebSocket -> HTTP fallback now.
            async with _DummyAsyncClient() as client:
                response = await federation_post(
                    client,
                    relay_url,
                    path="/relay/forward",
                    json=payload,
                )
                response.raise_for_status()
                return {"status": "forwarded"}

    async def federation_post(_client, _url, *, path, **_kwargs):
        http_paths.append(path)
        if path == "/internal/deliver":
            raise httpx.ConnectError("direct unavailable")
        return _OkResponse()

    monkeypatch.setattr(federation, "_get_target_curve_public_key", lambda *_args: _none())
    monkeypatch.setattr(federation, "_reachable_relays", lambda: _value(["http://relay-a"]))
    monkeypatch.setattr(federation, "_get_relay_transport", lambda: WsClient())
    monkeypatch.setattr(federation, "federation_post", federation_post)
    monkeypatch.setattr(federation.httpx, "AsyncClient", lambda **_kwargs: _DummyAsyncClient())
    monkeypatch.setattr(federation.settings, "relay_transport_mode", "websocket-preferred")

    await federation.deliver_to_remote_home_node(
        "http://home-b", envelope, conversation_meta
    )
    assert http_paths == ["/internal/deliver", "/relay/forward"]


async def _none():
    return None


async def _value(value):
    return value
