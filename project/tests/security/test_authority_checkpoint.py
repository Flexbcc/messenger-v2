from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.authority_checkpoint import (
    add_authority_signature,
    authority_checkpoint_hash,
    authority_state_from_checkpoint,
    authority_state_hash,
    build_authority_checkpoint,
    validate_authority_checkpoint,
)
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _state(prefix, epoch=4):
    keys = {f"{prefix}-{index}": SigningKey.generate() for index in range(7)}
    state = CapabilityAuthorityState(
        epoch=epoch,
        committee=tuple(sorted(keys)),
        threshold=5,
        validators={
            validator_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=NOW + timedelta(days=30),
            )
            for validator_id, key in keys.items()
        },
    )
    return keys, state


def _checkpoint(previous_state, next_state):
    return build_authority_checkpoint(
        authority_epoch=next_state.epoch,
        previous_hash=authority_state_hash(previous_state),
        committee=next_state.committee,
        threshold=next_state.threshold,
        validators=next_state.validators,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=7),
    )


def _sign(checkpoint, keys, count=5):
    for validator_id in sorted(keys)[:count]:
        checkpoint = add_authority_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return checkpoint


def _validate(checkpoint, previous_state):
    return validate_authority_checkpoint(
        checkpoint,
        now=NOW,
        previous_state=previous_state,
        expected_previous_hash=authority_state_hash(previous_state),
    )


def test_previous_five_of_seven_can_rotate_authority_set():
    previous_keys, previous = _state("old", epoch=4)
    _, next_state = _state("new", epoch=5)
    checkpoint = _sign(_checkpoint(previous, next_state), previous_keys, 5)
    result = _validate(checkpoint, previous)
    assert result.valid
    assert result.valid_signatures == 5
    restored = authority_state_from_checkpoint(checkpoint)
    assert restored.committee == next_state.committee
    assert restored.threshold == next_state.threshold
    assert restored.epoch == 5
    assert len(authority_checkpoint_hash(checkpoint)) == 64


def test_four_of_seven_cannot_rotate_authority():
    previous_keys, previous = _state("old", epoch=4)
    _, next_state = _state("new", epoch=5)
    result = _validate(_sign(_checkpoint(previous, next_state), previous_keys, 4), previous)
    assert not result.valid
    assert result.valid_signatures == 4


def test_new_committee_cannot_self_authorize_transition():
    _, previous = _state("old", epoch=4)
    new_keys, next_state = _state("new", epoch=5)
    result = _validate(_sign(_checkpoint(previous, next_state), new_keys, 5), previous)
    assert not result.valid
    assert result.reason == "signature outside previous committee"


def test_checkpoint_cannot_skip_epoch_or_break_previous_hash():
    previous_keys, previous = _state("old", epoch=4)
    _, skipped = _state("new", epoch=6)
    checkpoint = _sign(_checkpoint(previous, skipped), previous_keys, 5)
    result = _validate(checkpoint, previous)
    assert not result.valid
    assert result.reason == "authority epoch must advance exactly once"

    _, next_state = _state("newer", epoch=5)
    broken = _checkpoint(previous, next_state)
    broken["previous_hash"] = "0" * 64
    broken = _sign(broken, previous_keys, 5)
    result = _validate(broken, previous)
    assert not result.valid
    assert result.reason == "authority checkpoint chain is broken"


def test_tampered_new_validator_key_invalidates_quorum_signatures():
    previous_keys, previous = _state("old", epoch=4)
    _, next_state = _state("new", epoch=5)
    checkpoint = _sign(_checkpoint(previous, next_state), previous_keys, 5)
    first_validator = checkpoint["committee"][0]
    checkpoint["validators"][first_validator]["public_key"] = public_key_b64(
        SigningKey.generate()
    )
    result = _validate(checkpoint, previous)
    assert not result.valid
    assert result.reason == "insufficient previous-authority signatures"
