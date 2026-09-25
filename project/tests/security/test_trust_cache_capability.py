import time
import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

import shared.security.trust_cache as trust_cache_module
from shared.security.trust_cache import TrustCache


def _cache(node):
    cache = TrustCache("http://unused")
    cache._entries = {node["node_id"]: node}
    cache._fetched_at = time.time()
    return cache


@pytest.mark.asyncio
async def test_enforce_mode_rejects_self_advertised_infrastructure_capability(monkeypatch):
    monkeypatch.setattr(trust_cache_module, "FEDERATION_CAPABILITY_MODE", "enforce")
    cache = _cache(
        {
            "node_id": "sybil",
            "capabilities": ["relay"],
            "certified_capabilities": [],
            "capability_certificate_status": "absent",
        }
    )
    assert not await cache.has_capability("sybil", "relay")


@pytest.mark.asyncio
async def test_enforce_mode_accepts_quorum_certified_infrastructure_capability(monkeypatch):
    monkeypatch.setattr(trust_cache_module, "FEDERATION_CAPABILITY_MODE", "enforce")
    cache = _cache(
        {
            "node_id": "relay-a",
            "capabilities": ["relay"],
            "certified_capabilities": ["relay"],
            "capability_certificate_status": "valid",
        }
    )
    assert await cache.has_capability("relay-a", "relay")


@pytest.mark.asyncio
async def test_l0_home_capability_remains_available_for_own_traffic(monkeypatch):
    monkeypatch.setattr(trust_cache_module, "FEDERATION_CAPABILITY_MODE", "enforce")
    cache = _cache(
        {
            "node_id": "home-a",
            "capabilities": ["home"],
            "certified_capabilities": [],
            "capability_certificate_status": "absent",
        }
    )
    assert await cache.has_capability("home-a", "home")


@pytest.mark.asyncio
async def test_empty_catalog_is_negative_cached_and_refresh_is_single_flight(monkeypatch):
    response = MagicMock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"nodes": []}
    get = AsyncMock(return_value=response)

    class Client:
        def __init__(self, get_mock):
            self.get = get_mock

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

    monkeypatch.setattr(
        trust_cache_module.httpx, "AsyncClient", lambda **_kwargs: Client(get)
    )
    cache = TrustCache("https://discovery.example")
    results = await asyncio.gather(
        *(cache.is_trusted(f"unknown-{index}") for index in range(50))
    )
    assert results == [False] * 50
    assert get.await_count == 1


@pytest.mark.asyncio
async def test_catalog_is_indexed_by_alias_and_verified_identity_node_id(monkeypatch):
    response = MagicMock()
    response.raise_for_status.return_value = None
    response.json.return_value = {
        "nodes": [
            {
                "node_id": "relay-alias",
                "identity_node_id": "ouo-node-v1-identity",
                "trust_status": "trusted",
                "signing_public_key": "key",
            }
        ]
    }

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, _url):
            return response

    monkeypatch.setattr(trust_cache_module.httpx, "AsyncClient", lambda **_kwargs: Client())
    cache = TrustCache("https://discovery.example")
    assert await cache.is_trusted("relay-alias")
    assert await cache.is_trusted("ouo-node-v1-identity")
    assert await cache.signing_public_key("ouo-node-v1-identity") == "key"


@pytest.mark.asyncio
async def test_duplicate_identity_binding_is_not_cached(monkeypatch):
    response = MagicMock()
    response.raise_for_status.return_value = None
    response.json.return_value = {
        "nodes": [
            {"node_id": "a", "identity_node_id": "same", "trust_status": "trusted"},
            {"node_id": "b", "identity_node_id": "same", "trust_status": "trusted"},
        ]
    }

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, _url):
            return response

    monkeypatch.setattr(trust_cache_module.httpx, "AsyncClient", lambda **_kwargs: Client())
    cache = TrustCache("https://discovery.example")
    assert not await cache.is_trusted("same")
    assert await cache.is_trusted("a")
    assert await cache.is_trusted("b")
