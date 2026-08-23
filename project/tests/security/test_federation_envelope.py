import pytest
from nacl.signing import SigningKey

from shared.security.federation_envelope import (
    build_signed_federation_meta,
    ciphertext_hash,
    envelope_hash,
    sign_federation_meta,
    validate_federation_fields,
    verify_federation_meta_signature,
)
from shared.security.keys import public_key_b64


@pytest.fixture
def signing_key() -> SigningKey:
    return SigningKey.generate()


@pytest.fixture
def sample_envelope() -> dict:
    return {
        "packet_id": "pkt-1",
        "conversation_id": "conv-1",
        "sender_user_id": "user-a",
        "ciphertext": "base64-ciphertext-here",
        "content_type": "text",
    }


def test_ciphertext_hash_stable(sample_envelope):
    h1 = ciphertext_hash(sample_envelope)
    h2 = ciphertext_hash(sample_envelope)
    assert h1 == h2
    tampered = dict(sample_envelope, ciphertext="other")
    assert ciphertext_hash(tampered) != h1


def test_sign_and_verify_meta(signing_key, sample_envelope):
    meta = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=sample_envelope,
        route="direct",
    )
    pub = public_key_b64(signing_key)
    assert verify_federation_meta_signature(pub, meta)
    meta["ciphertext_hash"] = "tampered"
    assert not verify_federation_meta_signature(pub, meta)


def test_validate_fields_rejects_packet_mismatch(signing_key, sample_envelope):
    meta = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=sample_envelope,
    )
    bad_envelope = dict(sample_envelope, packet_id="other")
    assert validate_federation_fields(meta, envelope=bad_envelope) == "packet_id mismatch"


def test_validate_fields_rejects_hash_mismatch(signing_key, sample_envelope):
    meta = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=sample_envelope,
    )
    tampered = dict(sample_envelope, ciphertext="x")
    assert validate_federation_fields(meta, envelope=tampered) == "ciphertext_hash mismatch"


def test_non_ciphertext_envelope_tampering_is_rejected(signing_key, sample_envelope):
    meta = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=sample_envelope,
    )
    tampered = dict(sample_envelope, content_type="admin-command")
    assert validate_federation_fields(meta, envelope=tampered) == "envelope_hash mismatch"


def test_conversation_metadata_tampering_is_rejected(signing_key, sample_envelope):
    conversation_meta = {"conversation_id": "conv-1", "participant_user_ids": ["a", "b"]}
    meta = build_signed_federation_meta(
        signing_key=signing_key,
        origin_node_id="home-1",
        envelope=sample_envelope,
        conversation_meta=conversation_meta,
    )
    tampered = {"conversation_id": "conv-1", "participant_user_ids": ["a", "attacker"]}
    assert (
        validate_federation_fields(
            meta,
            envelope=sample_envelope,
            conversation_meta=tampered,
        )
        == "conversation_meta_hash mismatch"
    )


def test_canonical_signing_deterministic(signing_key):
    meta = {
        "packet_id": "p",
        "origin_node_id": "h",
        "nonce": "n",
        "ciphertext_hash": "abc",
    }
    s1 = sign_federation_meta(signing_key, meta)
    s2 = sign_federation_meta(signing_key, meta)
    assert s1["signature"] == s2["signature"]
