from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.randomness_checkpoint import (
    add_randomness_signature,
    build_randomness_checkpoint,
    randomness_checkpoint_hash,
    validate_randomness_checkpoint,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _authority():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    return keys, CapabilityAuthorityState(
        epoch=9,
        committee=tuple(sorted(keys)),
        threshold=5,
        validators={
            validator_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=NOW + timedelta(days=2),
            )
            for validator_id, key in keys.items()
        },
    )


def _observers():
    return [
        {
            "node_id": node_id_from_root_public_key(bytes([index]) * 32),
            "diversity_group": f"operator-{index}",
        }
        for index in range(1, 9)
    ]


def _checkpoint(authority):
    return build_randomness_checkpoint(
        challenge_epoch=12,
        authority_epoch=authority.epoch,
        previous_hash="11" * 32,
        randomness_seed="42" * 32,
        eligible_observers=_observers(),
        observer_count=5,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(hours=1),
        committee=authority.committee,
        threshold=authority.threshold,
    )


def _sign(checkpoint, keys, count=5):
    for validator_id in sorted(keys)[:count]:
        checkpoint = add_randomness_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return checkpoint


def _validate(checkpoint, authority):
    return validate_randomness_checkpoint(
        checkpoint,
        now=NOW,
        authority_state=authority,
        expected_previous_hash="11" * 32,
        minimum_challenge_epoch=11,
    )


def test_five_of_seven_approve_canonical_randomness_checkpoint():
    keys, authority = _authority()
    checkpoint = _sign(_checkpoint(authority), keys)
    validation = _validate(checkpoint, authority)
    assert validation.valid
    assert validation.valid_signatures == 5
    assert len(randomness_checkpoint_hash(checkpoint)) == 64


def test_four_signatures_and_seed_or_observer_tamper_fail_closed():
    keys, authority = _authority()
    assert not _validate(_sign(_checkpoint(authority), keys, 4), authority).valid

    seed_tamper = _sign(_checkpoint(authority), keys)
    seed_tamper["randomness_seed"] = "24" * 32
    assert not _validate(seed_tamper, authority).valid

    observer_tamper = _sign(_checkpoint(authority), keys)
    observer_tamper["eligible_observers"][0]["diversity_group"] = "attacker"
    assert not _validate(observer_tamper, authority).valid


def test_checkpoint_chain_epoch_and_authority_are_bound():
    keys, authority = _authority()
    checkpoint = _sign(_checkpoint(authority), keys)
    checkpoint["challenge_epoch"] = 13
    assert not _validate(checkpoint, authority).valid

    checkpoint = _sign(_checkpoint(authority), keys)
    checkpoint["previous_hash"] = "00" * 32
    assert not _validate(checkpoint, authority).valid

    checkpoint = _sign(_checkpoint(authority), keys)
    checkpoint["authority_epoch"] += 1
    assert not _validate(checkpoint, authority).valid
