from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.authority_checkpoint import authority_state_hash
from shared.security.capability_certificate import ValidatorCredential
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.challenge_assignment import (
    add_assignment_signature,
    build_challenge_assignment,
    validate_challenge_assignment,
)
from shared.security.challenge_scheduler import (
    build_challenge_assignment_proposal,
    selected_observers_from_checkpoint,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.randomness_checkpoint import (
    add_randomness_signature,
    build_randomness_checkpoint,
    randomness_checkpoint_hash,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _fixture():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    authority = CapabilityAuthorityState(
        epoch=3,
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
    observers = [
        {
            "node_id": node_id_from_root_public_key(bytes([index]) * 32),
            "diversity_group": f"operator-{index}",
        }
        for index in range(1, 9)
    ]
    checkpoint = build_randomness_checkpoint(
        challenge_epoch=19,
        authority_epoch=authority.epoch,
        previous_hash=authority_state_hash(authority),
        randomness_seed="42" * 32,
        eligible_observers=observers,
        observer_count=5,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(hours=1),
        committee=authority.committee,
        threshold=authority.threshold,
    )
    for validator_id in sorted(keys)[:5]:
        checkpoint = add_randomness_signature(
            checkpoint,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    subject = node_id_from_root_public_key(b"s" * 32)
    return keys, authority, checkpoint, subject


def _sign_assignment(assignment, keys):
    for validator_id in sorted(keys)[:5]:
        assignment = add_assignment_signature(
            assignment,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return assignment


def test_scheduler_builds_unsigned_deterministic_proposal_from_checkpoint():
    keys, authority, checkpoint, subject = _fixture()
    proposal = build_challenge_assignment_proposal(
        checkpoint=checkpoint,
        authority_state=authority,
        subject_node_id=subject,
        challenge_type="relay_delivery",
        not_before=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(minutes=30),
    )
    assert proposal["signatures"] == []
    assert proposal["epoch"] == checkpoint["challenge_epoch"]
    assert proposal["authority_epoch"] == authority.epoch
    assert proposal["randomness_commitment"] == randomness_checkpoint_hash(checkpoint)

    signed = _sign_assignment(proposal, keys)
    expected = selected_observers_from_checkpoint(
        checkpoint=checkpoint,
        subject_node_id=subject,
        challenge_type="relay_delivery",
    )
    validation = validate_challenge_assignment(
        signed,
        now=NOW,
        expected_observer_node_ids=expected,
        expected_committee=authority.committee,
        expected_threshold=authority.threshold,
        validator_credentials=authority.validators,
        expected_authority_epoch=authority.epoch,
        expected_randomness_commitment=randomness_checkpoint_hash(checkpoint),
    )
    assert validation.valid


def test_quorum_signed_but_wrong_observer_set_fails_external_selection():
    keys, authority, checkpoint, subject = _fixture()
    expected = selected_observers_from_checkpoint(
        checkpoint=checkpoint,
        subject_node_id=subject,
        challenge_type="relay_delivery",
    )
    wrong = build_challenge_assignment(
        subject_node_id=subject,
        observer_node_ids=[
            item["node_id"]
            for item in list(reversed(checkpoint["eligible_observers"]))[:5]
        ],
        challenge_type="relay_delivery",
        epoch=checkpoint["challenge_epoch"],
        authority_epoch=authority.epoch,
        randomness_commitment=randomness_checkpoint_hash(checkpoint),
        not_before=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(minutes=30),
        committee=authority.committee,
        threshold=authority.threshold,
    )
    wrong = _sign_assignment(wrong, keys)
    validation = validate_challenge_assignment(
        wrong,
        now=NOW,
        expected_observer_node_ids=expected,
        expected_committee=authority.committee,
        expected_threshold=authority.threshold,
        validator_credentials=authority.validators,
        expected_authority_epoch=authority.epoch,
        expected_randomness_commitment=randomness_checkpoint_hash(checkpoint),
    )
    assert not validation.valid
    assert validation.reason == "observer set does not match external selection"
