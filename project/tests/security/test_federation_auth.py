import os
import tempfile
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi import HTTPException
from starlette.requests import Request
from nacl.signing import SigningKey

from shared.security.canonical import body_sha256, signing_payload
from shared.security.federation_auth import (
    sign_federation_request,
    verify_federation_headers,
    verify_federation_request,
)
from shared.security.keys import public_key_b64, sign_message, verify_message
from shared.security.nonce_store import NonceStore
from shared.security.policy import allowed_capabilities
from shared.security.metrics import RateLimiter


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
    assert "home" in allowed_capabilities("POST", "/mailbox/store")
    assert "home" in allowed_capabilities("POST", "/mailbox/fetch")
    assert "home" in allowed_capabilities("POST", "/mailbox/ack")
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


def test_rate_limiter_has_hard_identity_bound():
    limiter = RateLimiter(rate=100, capacity=100, max_buckets=2)
    assert limiter.allow("node-a") is True
    assert limiter.allow("node-b") is True
    assert limiter.allow("node-c") is False
    assert limiter.bucket_count == 2


@pytest.mark.asyncio
async def test_unknown_node_flood_does_not_allocate_per_node_rate_state(
    monkeypatch, signing_key: SigningKey
):
    import shared.security.federation_auth as fed_auth

    monkeypatch.setattr(fed_auth, "INTERNAL_SECURITY_MODE", "signed")
    anonymous = RateLimiter(rate=10_000, capacity=10_000, max_buckets=1)
    trusted = RateLimiter(rate=100, capacity=100, max_buckets=10)
    monkeypatch.setattr(fed_auth, "_admission_rate_limiter", anonymous)
    monkeypatch.setattr(fed_auth, "_rate_limiter", trusted)
    cache = MagicMock()
    cache.is_trusted = AsyncMock(return_value=False)
    cache.has_capability = AsyncMock(return_value=False)
    cache.signing_public_key = AsyncMock(return_value=None)

    for index in range(100):
        body = b"{}"
        headers = sign_federation_request(
            signing_key=signing_key,
            node_id=f"unknown-{index}",
            method="POST",
            path="/mailbox/store",
            body=body,
        )
        with pytest.raises(HTTPException) as denied:
            await verify_federation_headers(
                headers,
                method="POST",
                path="/mailbox/store",
                body=body,
                trust_cache=cache,
                nonce_store=NonceStore(),
            )
        assert getattr(denied.value, "status_code", None) == 403

    assert anonymous.bucket_count == 1
    assert trusted.bucket_count == 0


@pytest.mark.asyncio
async def test_malformed_flood_is_rejected_before_body_trust_or_crypto(monkeypatch):
    import shared.security.federation_auth as fed_auth

    monkeypatch.setattr(fed_auth, "INTERNAL_SECURITY_MODE", "signed")
    cache = MagicMock()
    cache.is_trusted = AsyncMock(side_effect=AssertionError("trust lookup must not run"))
    request = MagicMock()
    request.method = "POST"
    request.url.path = "/buffer"
    request.headers = {}
    request.body = AsyncMock(side_effect=AssertionError("body must not be read"))
    crypto = MagicMock(side_effect=AssertionError("crypto must not run"))
    monkeypatch.setattr(fed_auth, "verify_message", crypto)

    for _ in range(1000):
        with pytest.raises(HTTPException) as denied:
            await fed_auth.verify_federation_request(
                request,
                trust_cache=cache,
                nonce_store=NonceStore(),
            )
        assert denied.value.status_code == 401
    request.body.assert_not_awaited()
    cache.is_trusted.assert_not_awaited()
    crypto.assert_not_called()


@pytest.mark.asyncio
async def test_unknown_signed_origin_is_rejected_before_streaming_body(
    monkeypatch, signing_key: SigningKey
):
    import shared.security.federation_auth as fed_auth

    monkeypatch.setattr(fed_auth, "INTERNAL_SECURITY_MODE", "signed")
    headers = sign_federation_request(
        signing_key=signing_key,
        node_id="unknown-node",
        method="POST",
        path="/buffer",
        body=b"never-read",
    )
    received = 0

    async def receive():
        nonlocal received
        received += 1
        raise AssertionError("unknown origin body must not be streamed")

    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/buffer",
            "headers": [(key.lower().encode(), value.encode()) for key, value in headers.items()],
        },
        receive,
    )
    cache = MagicMock()
    cache.is_trusted = AsyncMock(return_value=False)
    with pytest.raises(HTTPException) as denied:
        await fed_auth.verify_federation_request(
            request,
            trust_cache=cache,
            nonce_store=NonceStore(),
        )
    assert denied.value.status_code == 403
    assert received == 0


@pytest.mark.asyncio
async def test_chunked_body_limit_rejects_before_signature_and_nonce(
    monkeypatch, signing_key: SigningKey, trust_cache
):
    import shared.security.federation_auth as fed_auth

    monkeypatch.setattr(fed_auth, "INTERNAL_SECURITY_MODE", "signed")
    monkeypatch.setattr(fed_auth, "FEDERATION_MAX_BODY_BYTES", 8)
    headers = sign_federation_request(
        signing_key=signing_key,
        node_id="home-1",
        method="POST",
        path="/buffer",
        body=b"0123456789",
    )
    messages = iter(
        [
            {"type": "http.request", "body": b"01234", "more_body": True},
            {"type": "http.request", "body": b"56789", "more_body": False},
        ]
    )

    async def receive():
        return next(messages)

    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/buffer",
            "headers": [(key.lower().encode(), value.encode()) for key, value in headers.items()],
        },
        receive,
    )
    crypto = MagicMock(side_effect=AssertionError("signature must not run"))
    monkeypatch.setattr(fed_auth, "verify_message", crypto)
    nonce_store = MagicMock()
    with pytest.raises(HTTPException) as denied:
        await fed_auth.verify_federation_request(
            request,
            trust_cache=trust_cache,
            nonce_store=nonce_store,
        )
    assert denied.value.status_code == 413
    crypto.assert_not_called()
    nonce_store.consume.assert_not_called()


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
