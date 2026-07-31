import pytest
from unittest.mock import AsyncMock, MagicMock

from shared.security.audit_log import FederationAuditLog
from shared.security.envelope_verify import verify_incoming_federation
from shared.security.federation_envelope import build_signed_federation_meta
from shared.security.keys import public_key_b64
from shared.security.nonce_store import NonceStore
from nacl.signing import SigningKey


@pytest.fixture
def signing_key() -> SigningKey:
    return SigningKey.generate()


@pytest.fixture
def trust_cache(signing_key: SigningKey):
    cache = MagicMock()
    cache.is_trusted = AsyncMock(return_value=True)
    cache.signing_public_key = AsyncMock(return_value=public_key_b64(signing_key))
    return cache


@pytest.mark.asyncio
async def test_verify_consumes_nonce_once(monkeypatch, signing_key, trust_cache):
    monkeypatch.setenv("FEDERATION_ENVELOPE_MODE", "signed")
    import shared.security.config as cfg
    import shared.security.envelope_verify as ev

    cfg.FEDERATION_ENVELOPE_MODE = "signed"
    ev.FEDERATION_ENVELOPE_MODE = "signed"

    envelope = {
        "packet_id": "pkt-1",
        "conversation_id": "c1",
        "sender_user_id": "u1",
        "ciphertext": "ct",
    }
    federation = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=envelope,
    )
    nonce_store = NonceStore()
    audit = FederationAuditLog()

    origin = await verify_incoming_federation(
        federation=federation,
        envelope=envelope,
        endpoint="/internal/deliver",
        trust_cache=trust_cache,
        nonce_store=nonce_store,
        audit=audit,
        expected_origin_node_id="home-1",
    )
    assert origin == "home-1"

    with pytest.raises(Exception):
        await verify_incoming_federation(
            federation=federation,
            envelope=envelope,
            endpoint="/internal/deliver",
            trust_cache=trust_cache,
            nonce_store=nonce_store,
            audit=audit,
        )
