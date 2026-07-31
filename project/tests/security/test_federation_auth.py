import os
import tempfile
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

import pytest
from nacl.signing import SigningKey

from shared.security.canonical import body_sha256, signing_payload
from shared.security.federation_auth import sign_federation_request, verify_federation_request
from shared.security.keys import public_key_b64, sign_message, verify_message
from shared.security.nonce_store import NonceStore
from shared.security.policy import allowed_capabilities


@pytest.fixture
def signing_key() -> SigningKey:
    return SigningKey.generate()


@pytest.fixture
def trust_cache(signing_key: SigningKey):
    cache = MagicMock()
    cache.is_trusted = AsyncMock(return_value=True)
    cache.has_capability = AsyncMock(return_value=True)
    cache.signing_public_key = AsyncMock(return_value=public_key_b64(signing_key))
    return cache


def test_signing_payload_format():
    body = b'{"a":1}'
    msg = signing_payload(
        node_id="home-1",
        timestamp="2026-07-06T12:00:00Z",
        nonce="n1",
        method="post",
        path="/internal/deliver",
        body=body,
    )
    expected_digest = body_sha256(body)
    assert msg == (
        f"home-1|2026-07-06T12:00:00Z|n1|POST|/internal/deliver|{expected_digest}".encode()
    )


def test_sign_and_verify_roundtrip(signing_key: SigningKey):
    message = b"test-payload"
    sig = sign_message(signing_key, message)
    pub = public_key_b64(signing_key)
    assert verify_message(pub, message, sig)
    assert not verify_message(pub, b"tampered", sig)


def test_nonce_store_rejects_replay():
    store = NonceStore()
    assert store.consume("nonce-1", "home-1", 60) is True
    assert store.consume("nonce-1", "home-1", 60) is False


def test_nonce_store_sqlite_persists():
    with tempfile.TemporaryDirectory() as tmp:
        db_path = os.path.join(tmp, "nonces.db")
        store = NonceStore(db_path)
        assert store.consume("n-sql", "relay-1", 60) is True
        store2 = NonceStore(db_path)
        assert store2.consume("n-sql", "relay-1", 60) is False


def test_allowed_capabilities_buffer_prefix():
    assert "home" in allowed_capabilities("GET", "/buffer/user-123")
    assert "home" in allowed_capabilities("DELETE", "/buffer/entry-uuid")
    assert "relay" in allowed_capabilities("POST", "/relay/forward")


def test_sign_federation_request_headers(signing_key: SigningKey):
    body = b'{"x":1}'
    headers = sign_federation_request(
        signing_key=signing_key,
        node_id="home-1",
        method="POST",
        path="/buffer",
        body=body,
    )
    assert headers["X-Federation-Node-Id"] == "home-1"
    assert headers["X-Federation-Nonce"]
    assert headers["X-Federation-Signature"]


@pytest.mark.asyncio
async def test_verify_federation_request_signed_mode(monkeypatch, signing_key: SigningKey, trust_cache):
    monkeypatch.setenv("INTERNAL_SECURITY_MODE", "signed")
    import shared.security.config as cfg
    import shared.security.federation_auth as fed_auth
    import shared.security.http_client as http_client

    cfg.INTERNAL_SECURITY_MODE = "signed"
    fed_auth.INTERNAL_SECURITY_MODE = "signed"
    http_client.INTERNAL_SECURITY_MODE = "signed"

    body = b'{"envelope":{}}'
    headers = sign_federation_request(
        signing_key=signing_key,
        node_id="home-1",
        method="POST",
        path="/buffer",
        body=body,
    )

    request = MagicMock()
    request.method = "POST"
    request.url.path = "/buffer"
    request.headers = headers
    request.body = AsyncMock(return_value=body)

    nonce_store = NonceStore()
    node_id = await verify_federation_request(
        request,
        trust_cache=trust_cache,
        nonce_store=nonce_store,
        path="/buffer",
    )
    assert node_id == "home-1"

    with pytest.raises(Exception):
        await verify_federation_request(
            request,
            trust_cache=trust_cache,
            nonce_store=nonce_store,
            path="/buffer",
        )


@pytest.mark.asyncio
async def test_verify_federation_legacy_mode(monkeypatch, trust_cache):
    monkeypatch.setenv("INTERNAL_SECURITY_MODE", "legacy")
    import shared.security.config as cfg
    import shared.security.federation_auth as fed_auth

    cfg.INTERNAL_SECURITY_MODE = "legacy"
    fed_auth.INTERNAL_SECURITY_MODE = "legacy"

    request = MagicMock()
    request.method = "POST"
    request.url.path = "/buffer"
    request.headers = {"X-Federation-Node-Id": "home-1"}
    request.body = AsyncMock(return_value=b"{}")

    node_id = await verify_federation_request(
        request,
        trust_cache=trust_cache,
        nonce_store=NonceStore(),
    )
    assert node_id == "home-1"
