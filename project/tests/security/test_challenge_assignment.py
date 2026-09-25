import hashlib
from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import ValidatorCredential
from shared.security.challenge_assignment import (
    add_assignment_signature,
    build_challenge_assignment,
    issue_assignment_ack,
    validate_assignment_ack,
    validate_challenge_assignment,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _node_id():
    return node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))


def _validators():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    credentials = {
        validator_id: ValidatorCredential(
            public_key=public_key_b64(key), valid_until=NOW + timedelta(days=1)
        )
        for validator_id, key in keys.items()
    }
    return keys, credentials


def _assignment(keys, observers):
    return build_challenge_assignment(
        subject_node_id=_node_id(),
        observer_node_ids=observers,
        challenge_type="relay_delivery",
        epoch=4,
        randomness_commitment=hashlib.sha256(b"authority-randomness").hexdigest(),
        not_before=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(minutes=30),
        committee=sorted(keys),
        threshold=5,
    )


def _sign(assignment, keys, count):
    for validator_id in sorted(keys)[:count]:
        assignment = add_assignment_signature(
            assignment,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return assignment


def _validate(assignment, credentials, keys, observers):
    return validate_challenge_assignment(
        assignment,
        now=NOW,
        expected_observer_node_ids=observers,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )


def test_five_of_seven_can_assign_external_observers():
    keys, credentials = _validators()
    observers = [_node_id(), _node_id()]
    result = _validate(_sign(_assignment(keys, observers), keys, 5), credentials, keys, observers)
    assert result.valid
    assert result.valid_signatures == 5


def test_four_of_seven_cannot_issue_assignment():
    keys, credentials = _validators()
    observers = [_node_id(), _node_id()]
    result = _validate(_sign(_assignment(keys, observers), keys, 4), credentials, keys, observers)
    assert not result.valid
    assert result.valid_signatures == 4


def test_subject_cannot_replace_externally_selected_observer_set():
    keys, credentials = _validators()
    selected = [_node_id(), _node_id()]
    chosen = [_node_id(), _node_id()]
    result = _validate(_sign(_assignment(keys, chosen), keys, 5), credentials, keys, selected)
    assert not result.valid
    assert result.reason == "observer set does not match external selection"


def test_expired_validator_does_not_count():
    keys, credentials = _validators()
    observers = [_node_id()]
    credentials["validator-0"] = ValidatorCredential(
        public_key=credentials["validator-0"].public_key,
        valid_until=NOW - timedelta(seconds=1),
    )
    result = _validate(_sign(_assignment(keys, observers), keys, 5), credentials, keys, observers)
    assert not result.valid
    assert result.valid_signatures == 4


def test_assignment_epoch_rollback_is_rejected():
    keys, credentials = _validators()
    observers = [_node_id()]
    assignment = _sign(_assignment(keys, observers), keys, 5)
    result = validate_challenge_assignment(
        assignment,
        now=NOW,
        expected_observer_node_ids=observers,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
        minimum_epoch=5,
    )
    assert not result.valid
    assert result.reason == "challenge assignment rollback detected"


def test_observer_signed_ack_is_bound_to_assignment_and_decision():
    observer_key = SigningKey.generate()
    observer_id = _node_id()
    ack = issue_assignment_ack(
        assignment_id="c7f07755-0ad9-4e8a-9f12-456a4139119a",
        observer_node_id=observer_id,
        decision="accepted",
        acknowledged_at=NOW,
        observer_signing_key=observer_key,
    )
    result = validate_assignment_ack(
        ack,
        now=NOW,
        expected_assignment_id=ack["assignment_id"],
        expected_observer_node_id=observer_id,
        observer_credential=ValidatorCredential(
            public_key=public_key_b64(observer_key),
            valid_until=NOW + timedelta(days=1),
        ),
        assignment_not_before=NOW - timedelta(minutes=1),
        assignment_expires_at=NOW + timedelta(minutes=30),
    )
    assert result.valid

    tampered = dict(ack)
    tampered["decision"] = "declined"
    rejected = validate_assignment_ack(
        tampered,
        now=NOW,
        expected_assignment_id=ack["assignment_id"],
        expected_observer_node_id=observer_id,
        observer_credential=ValidatorCredential(
            public_key=public_key_b64(observer_key),
            valid_until=NOW + timedelta(days=1),
        ),
        assignment_not_before=NOW - timedelta(minutes=1),
        assignment_expires_at=NOW + timedelta(minutes=30),
    )
    assert not rejected.valid
    assert rejected.reason == "invalid observer ack signature"


def test_ack_from_wrong_observer_is_rejected_before_signature_acceptance():
    observer_key = SigningKey.generate()
    observer_id = _node_id()
    ack = issue_assignment_ack(
        assignment_id="f6997f47-9431-4d3d-9bf5-90f1f94cc1a2",
        observer_node_id=observer_id,
        decision="accepted",
        acknowledged_at=NOW,
        observer_signing_key=observer_key,
    )
    result = validate_assignment_ack(
        ack,
        now=NOW,
        expected_assignment_id=ack["assignment_id"],
        expected_observer_node_id=_node_id(),
        observer_credential=ValidatorCredential(
            public_key=public_key_b64(observer_key),
            valid_until=NOW + timedelta(days=1),
        ),
        assignment_not_before=NOW - timedelta(minutes=1),
        assignment_expires_at=NOW + timedelta(minutes=30),
    )
    assert not result.valid
    assert result.reason == "ack observer_node_id mismatch"
