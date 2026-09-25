from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.bootstrap_record import user_id_from_identity_public_key
from shared.security.keys import public_key_b64
from shared.security.route_descriptor import (
    issue_route_descriptor,
    route_descriptor_commitment,
    route_descriptor_hash,
    validate_route_descriptor,
    validate_route_transition,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
INGRESS = [
    {"node_id": "ingress-a", "endpoint": "https://a.example", "transport": "https"},
    {"node_id": "ingress-b", "endpoint": "wss://b.example/ws", "transport": "wss"},
]


def _descriptor(key, epoch=10, **kwargs):
    return issue_route_descriptor(
        identity_signing_key=key,
        identity_version=1,
        route_epoch=epoch,
        ingress_set=INGRESS,
        valid_from=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(hours=1),
        **kwargs,
    )


def _validate(descriptor, key, **kwargs):
    return validate_route_descriptor(
        descriptor,
        identity_public_key=public_key_b64(key),
        expected_user_id=user_id_from_identity_public_key(bytes(key.verify_key)),
        now=NOW,
        **kwargs,
    )


def test_signed_route_descriptor_is_valid():
    key = SigningKey.generate()
    assert _validate(_descriptor(key), key).valid


def test_ingress_tampering_breaks_signature():
    key = SigningKey.generate()
    descriptor = _descriptor(key)
    descriptor["ingress_set"][0]["endpoint"] = "https://evil.example"
    result = _validate(descriptor, key)
    assert not result.valid
    assert result.reason == "invalid identity signature"


def test_old_route_epoch_is_rejected():
    key = SigningKey.generate()
    result = _validate(_descriptor(key, epoch=9), key, minimum_route_epoch=10)
    assert not result.valid
    assert result.reason == "invalid or stale route_epoch"


def test_current_next_transition_is_hash_linked():
    key = SigningKey.generate()
    next_draft = _descriptor(key, epoch=11, previous_hash="0" * 64)
    current = _descriptor(
        key,
        epoch=10,
        next_descriptor_commitment=route_descriptor_commitment(next_draft),
    )
    next_descriptor = _descriptor(
        key,
        epoch=11,
        previous_hash=route_descriptor_hash(current),
    )
    assert route_descriptor_commitment(next_draft) == route_descriptor_commitment(next_descriptor)
    assert validate_route_transition(current, next_descriptor).valid


def test_non_consecutive_transition_is_rejected():
    key = SigningKey.generate()
    current = _descriptor(key, epoch=10)
    future = _descriptor(key, epoch=12, previous_hash=route_descriptor_hash(current))
    result = validate_route_transition(current, future)
    assert not result.valid
    assert result.reason == "route epoch is not consecutive"


def test_future_descriptor_requires_explicit_preload_mode():
    key = SigningKey.generate()
    future = issue_route_descriptor(
        identity_signing_key=key,
        identity_version=1,
        route_epoch=11,
        ingress_set=INGRESS,
        valid_from=NOW + timedelta(hours=1),
        valid_until=NOW + timedelta(hours=2),
    )
    assert not _validate(future, key).valid
    assert _validate(future, key, allow_future=True).valid
