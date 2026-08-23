from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from nacl.signing import SigningKey

from app import federation, peer_runtime
from shared.security.node_identity import node_id_from_root_public_key


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
NODE_IDS = [
    node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    for _ in range(10)
]


def _candidate(index):
    return {
        "node_id": NODE_IDS[index],
        "endpoint": f"wss://relay-{index}.example/relay/ws",
        "capabilities": ["relay"],
        "observed_by": ["d1", "d2"],
        "diversity_group": f"operator-{index}",
        "validated": True,
    }


@pytest.mark.asyncio
async def test_refresh_persists_locally_seeded_guards_and_relay_urls(tmp_path, monkeypatch):
    authority = SimpleNamespace(epoch=5)
    monkeypatch.setattr(peer_runtime.settings, "peer_authority_state_path", "authority.json")
    monkeypatch.setattr(peer_runtime.settings, "peer_discovery_source_set_path", "sources.json")
    monkeypatch.setattr(peer_runtime.settings, "peer_selection_seed_path", str(tmp_path / "seed"))
    monkeypatch.setattr(peer_runtime.settings, "peer_selection_state_path", str(tmp_path / "state.json"))
    monkeypatch.setattr(peer_runtime.settings, "peer_selection_rotation_seconds", 3600)
    monkeypatch.setattr(peer_runtime, "load_capability_authority_state", lambda _path: authority)
    monkeypatch.setattr(
        peer_runtime,
        "load_discovery_source_credentials",
        lambda *_args, **_kwargs: {"d1": object(), "d2": object()},
    )

    async def observations(_client):
        return [{"opaque": True}]

    monkeypatch.setattr(peer_runtime, "_fetch_observations", observations)
    monkeypatch.setattr(
        peer_runtime,
        "aggregate_discovery_peer_view",
        lambda *_args, **_kwargs: SimpleNamespace(
            candidates=tuple(_candidate(index) for index in range(10)),
            conflicts=(),
            rejected_count=0,
        ),
    )
    monkeypatch.setattr(
        peer_runtime,
        "node_identity_registration_fields",
        lambda **_kwargs: {"operational_certificate": {"node_id": "home-self"}},
    )

    class Client:
        pass

    result = await peer_runtime.refresh_signed_peer_set(client=Client(), now=NOW)
    assert result == {
        "relay_count": 6,
        "reserve_count": 2,
        "eligible_count": 10,
        "degraded": False,
        "conflicts": [],
        "rejected_count": 0,
    }
    assert len(peer_runtime.signed_relay_urls(now=NOW)) == 6
    assert len(peer_runtime.signed_reserve_urls(now=NOW)) == 2
    assert all(url.startswith("https://relay-") for url in peer_runtime.signed_relay_urls(now=NOW))
    assert all(not url.endswith("/relay/ws") for url in peer_runtime.signed_relay_urls(now=NOW))
    assert (tmp_path / "seed").exists()
    assert (tmp_path / "state.json").exists()


def test_in_memory_signed_peer_set_expires_fail_closed(monkeypatch):
    monkeypatch.setattr(peer_runtime, "_relay_urls", ("https://relay.example",))
    monkeypatch.setattr(peer_runtime, "_reserve_urls", ("https://reserve.example",))
    monkeypatch.setattr(peer_runtime, "_valid_until", NOW + timedelta(minutes=5))
    assert peer_runtime.signed_relay_urls(now=NOW) == ["https://relay.example"]
    assert peer_runtime.signed_reserve_urls(now=NOW) == ["https://reserve.example"]
    assert peer_runtime.signed_relay_urls(now=NOW + timedelta(minutes=6)) == []
    assert peer_runtime.signed_reserve_urls(now=NOW + timedelta(minutes=6)) == []


def test_invalid_persisted_state_clears_previous_in_memory_peers(tmp_path, monkeypatch):
    monkeypatch.setattr(peer_runtime.settings, "peer_selection_state_path", str(tmp_path / "missing.json"))
    monkeypatch.setattr(peer_runtime, "_relay_urls", ("https://stale.example",))
    monkeypatch.setattr(peer_runtime, "_reserve_urls", ("https://stale-reserve.example",))
    monkeypatch.setattr(peer_runtime, "_valid_until", NOW + timedelta(hours=1))
    peer_runtime._load_persisted(NOW)
    assert peer_runtime.signed_relay_urls(now=NOW) == []
    assert peer_runtime.signed_reserve_urls(now=NOW) == []


@pytest.mark.asyncio
async def test_enforce_mode_does_not_fall_back_to_unsigned_discovery(monkeypatch):
    monkeypatch.setattr(federation.settings, "signed_peer_selection_mode", "enforce")
    monkeypatch.setattr(peer_runtime, "signed_relay_urls", lambda: [])
    assert await federation._list_discovery_nodes("relay", None) == []


def test_enforce_startup_requires_at_least_two_discovery_origins(monkeypatch):
    monkeypatch.setattr(peer_runtime.settings, "signed_peer_selection_mode", "enforce")
    monkeypatch.setattr(peer_runtime.settings, "peer_discovery_urls", ("https://d1.example",))
    monkeypatch.setattr(peer_runtime, "_load_persisted", lambda _now: None)
    with pytest.raises(RuntimeError, match="at least two Discovery URLs"):
        peer_runtime.start_peer_runtime()


@pytest.mark.asyncio
async def test_reserves_are_used_only_after_all_active_relays_fail(monkeypatch):
    monkeypatch.setattr(federation.settings, "resource_policy", "federated")
    monkeypatch.setattr(federation.settings, "signed_peer_selection_mode", "enforce")
    monkeypatch.setattr(peer_runtime, "signed_relay_urls", lambda: ["https://active"])
    monkeypatch.setattr(peer_runtime, "signed_reserve_urls", lambda: ["https://reserve"])
    calls = []

    async def rank(urls):
        calls.append(urls)
        return [] if urls == ["https://active"] else urls

    monkeypatch.setattr(federation, "_rank_reachable", rank)
    assert await federation._reachable_relays() == ["https://reserve"]
    assert calls == [["https://active"], ["https://reserve"]]
