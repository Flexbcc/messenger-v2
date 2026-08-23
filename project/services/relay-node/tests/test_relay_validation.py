from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException

from app import main


def _payload(**overrides):
    payload = {
        "target_home_node_url": "http://home-b:8001",
        "hop_count": 1,
        "envelope": {"packet_id": "packet-1", "ciphertext": "opaque"},
        "conversation_meta": {"conversation_id": "conversation-1"},
        "federation": {"origin_node_id": "home-a"},
    }
    payload.update(overrides)
    return payload


def test_websocket_connection_budget_is_global_and_per_peer(monkeypatch):
    monkeypatch.setattr(main.settings, "ws_max_connections", 2)
    monkeypatch.setattr(main.settings, "ws_max_connections_per_peer", 1)
    monkeypatch.setattr(main, "_active_ws_connections", 0)
    main._active_ws_by_peer.clear()

    assert main._reserve_ws_connection() is True
    assert main._reserve_ws_connection() is True
    assert main._reserve_ws_connection() is False
    assert main._bind_ws_connection_to_peer("home-a") is True
    assert main._bind_ws_connection_to_peer("home-a") is False
    assert main._bind_ws_connection_to_peer("home-b") is True

    main._release_ws_connection("home-a")
    assert main._active_ws_connections == 1
    assert "home-a" not in main._active_ws_by_peer
    main._release_ws_connection("home-b")
    assert main._active_ws_connections == 0
    assert main._active_ws_by_peer == {}


@pytest.mark.parametrize("value", [0, -1, 3, True, "2", "not-a-number"])
def test_invalid_hop_count_returns_400_instead_of_crashing(value):
    with pytest.raises(HTTPException) as exc:
        main._validate_forward_payload(_payload(hop_count=value))
    assert exc.value.status_code == 400


@pytest.mark.parametrize(
    "url",
    ["file:///etc/passwd", "http://user:password@internal", "", None, "ftp://host/path"],
)
def test_invalid_or_credentialed_target_url_is_rejected(url):
    with pytest.raises(HTTPException) as exc:
        main._validate_forward_payload(_payload(target_home_node_url=url))
    assert exc.value.status_code == 400


@pytest.mark.asyncio
async def test_enforce_mode_rejects_target_outside_trusted_catalog(monkeypatch):
    security = MagicMock()
    security.trust_cache = MagicMock()
    security.nonce_store = MagicMock()
    security.audit_log = MagicMock()
    monkeypatch.setattr(main, "get_federation_security", lambda: security)
    monkeypatch.setattr(main, "verify_incoming_federation", AsyncMock(return_value=None))
    monkeypatch.setattr(main, "_target_is_trusted_home", AsyncMock(return_value=False))
    monkeypatch.setattr(main.settings, "target_validation_mode", "enforce")

    with pytest.raises(HTTPException) as exc:
        await main.forward(_payload(), _verified="home-a")
    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_report_mode_keeps_legacy_delivery_path(monkeypatch):
    security = MagicMock()
    security.signing_key = MagicMock()
    security.node_id = "relay-a"
    security.trust_cache = MagicMock()
    security.nonce_store = MagicMock()
    security.audit_log = MagicMock()
    response = MagicMock()
    response.raise_for_status.return_value = None
    monkeypatch.setattr(main, "get_federation_security", lambda: security)
    monkeypatch.setattr(main, "verify_incoming_federation", AsyncMock(return_value=None))
    monkeypatch.setattr(main, "_target_is_trusted_home", AsyncMock(return_value=False))
    monkeypatch.setattr(main, "federation_post", AsyncMock(return_value=response))
    monkeypatch.setattr(main.settings, "target_validation_mode", "report")

    result = await main.forward(_payload(), _verified="home-a")
    assert result["status"] == "forwarded"
    assert result["route"] == "relay_direct"
