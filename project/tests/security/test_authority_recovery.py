from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.authority_checkpoint import build_authority_checkpoint
from shared.security.authority_recovery import (
    add_recovery_signature,
    authority_recovery_hash,
    build_authority_recovery,
    replacement_checkpoint_hash,
    validate_authority_recovery,
)
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _state(prefix, count, threshold, epoch=1):
    keys = {f"{prefix}-{index}": SigningKey.generate() for index in range(count)}
    state = CapabilityAuthorityState(
        epoch=epoch,
        committee=tuple(sorted(keys)),
        threshold=threshold,
        validators={
            key_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=NOW + timedelta(days=30),
            )
            for key_id, key in keys.items()
        },
    )
    return keys, state


def _recovery(recovery_state, replacement_state, compromised_epoch=20):
    replacement = build_authority_checkpoint(
        authority_epoch=replacement_state.epoch,
        previous_hash="a" * 64,
        committee=replacement_state.committee,
        threshold=replacement_state.threshold,
        validators=replacement_state.validators,
        issued_at=NOW,
        valid_until=NOW + timedelta(days=7),
    )
    return build_authority_recovery(
        compromised_authority_epoch=compromised_epoch,
        replacement_checkpoint=replacement,
        reason_code="authority_quorum_compromise",
        issued_at=NOW,
        expires_at=NOW + timedelta(hours=1),
        recovery_committee=recovery_state.committee,
        recovery_threshold=recovery_state.threshold,
    )


def _sign(recovery, keys, count):
    for key_id in sorted(keys)[:count]:
        recovery = add_recovery_signature(
            recovery,
            recovery_key_id=key_id,
            recovery_signing_key=keys[key_id],
        )
    return recovery


def test_three_of_five_offline_keys_authorize_advancing_replacement():
    recovery_keys, recovery_state = _state("recovery", 5, 3)
    _, replacement_state = _state("new-authority", 7, 5, epoch=21)
    recovery = _sign(_recovery(recovery_state, replacement_state), recovery_keys, 3)
    result = validate_authority_recovery(
        recovery,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert result.valid
    assert result.valid_signatures == 3
    assert len(authority_recovery_hash(recovery)) == 64
    assert len(replacement_checkpoint_hash(recovery)) == 64


def test_two_of_five_cannot_recover_authority():
    recovery_keys, recovery_state = _state("recovery", 5, 3)
    _, replacement_state = _state("new-authority", 7, 5, epoch=21)
    recovery = _sign(_recovery(recovery_state, replacement_state), recovery_keys, 2)
    result = validate_authority_recovery(
        recovery,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert not result.valid
    assert result.valid_signatures == 2


def test_compromised_normal_authority_cannot_sign_emergency_recovery():
    _, recovery_state = _state("recovery", 5, 3)
    normal_keys, _ = _state("normal", 7, 5, epoch=20)
    _, replacement_state = _state("new-authority", 7, 5, epoch=21)
    recovery = _sign(_recovery(recovery_state, replacement_state), normal_keys, 3)
    result = validate_authority_recovery(
        recovery,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert not result.valid
    assert result.reason == "signature outside recovery committee"


def test_recovery_must_cover_highest_epoch_and_advance_replacement():
    recovery_keys, recovery_state = _state("recovery", 5, 3)
    _, replacement_state = _state("new-authority", 7, 5, epoch=21)
    stale = _sign(
        _recovery(recovery_state, replacement_state, compromised_epoch=19),
        recovery_keys,
        3,
    )
    result = validate_authority_recovery(
        stale,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert not result.valid
    assert result.reason == "recovery does not cover highest authority epoch"

    _, non_advancing_state = _state("newer", 7, 5, epoch=20)
    non_advancing = _sign(
        _recovery(recovery_state, non_advancing_state, compromised_epoch=20),
        recovery_keys,
        3,
    )
    result = validate_authority_recovery(
        non_advancing,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert not result.valid
    assert result.reason == "replacement authority epoch must advance"


def test_tampering_replacement_after_ceremony_invalidates_recovery_signatures():
    recovery_keys, recovery_state = _state("recovery", 5, 3)
    _, replacement_state = _state("new-authority", 7, 5, epoch=21)
    recovery = _sign(_recovery(recovery_state, replacement_state), recovery_keys, 3)
    recovery["replacement_checkpoint"]["threshold"] = 4
    result = validate_authority_recovery(
        recovery,
        now=NOW,
        recovery_state=recovery_state,
        minimum_authority_epoch=20,
    )
    assert not result.valid
    assert result.reason == "insufficient offline recovery signatures"
