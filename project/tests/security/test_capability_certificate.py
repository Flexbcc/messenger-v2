from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
    validate_capability_certificate,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
SUBJECT = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))


def _validators(count=7):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(count)}
    credentials = {
        validator_id: ValidatorCredential(
            public_key=public_key_b64(key),
            valid_until=NOW + timedelta(days=2),
        )
        for validator_id, key in keys.items()
    }
    return keys, credentials


def _certificate(committee, threshold=5, level=2, capabilities=("relay",), epoch=10):
    return build_capability_certificate(
        subject_node_id=SUBJECT,
        level=level,
        capabilities=capabilities,
        quotas={"max_connections": 100},
        epoch=epoch,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=1),
        committee=committee,
        threshold=threshold,
    )


def _sign(certificate, keys, validator_ids):
    result = certificate
    for validator_id in validator_ids:
        result = add_validator_signature(
            result,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return result


def _validate(certificate, credentials, committee, **kwargs):
    return validate_capability_certificate(
        certificate,
        now=NOW,
        expected_committee=committee,
        expected_threshold=5,
        validator_credentials=credentials,
        **kwargs,
    )


def test_five_of_seven_valid_signatures_can_issue_capability():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _sign(_certificate(committee), keys, committee[:5])
    result = _validate(certificate, credentials, committee)
    assert result.valid
    assert result.valid_signatures == 5


def test_four_of_seven_cannot_issue_five_of_seven_capability():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _sign(_certificate(committee), keys, committee[:4])
    result = _validate(certificate, credentials, committee)
    assert not result.valid
    assert result.valid_signatures == 4


def test_candidate_supplied_committee_is_rejected():
    keys, credentials = _validators()
    actual_committee = list(keys)
    chosen_committee = actual_committee[:5]
    certificate = _sign(
        _certificate(chosen_committee, threshold=5),
        keys,
        chosen_committee,
    )
    result = _validate(certificate, credentials, actual_committee)
    assert not result.valid
    assert result.reason == "committee does not match externally selected committee"


def test_duplicate_validator_signature_does_not_count_twice():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _sign(_certificate(committee), keys, committee[:4])
    certificate = add_validator_signature(
        certificate,
        validator_id=committee[0],
        validator_signing_key=keys[committee[0]],
    )
    result = _validate(certificate, credentials, committee)
    assert not result.valid
    assert result.reason == "duplicate validator signature"


def test_revoked_and_expired_validators_do_not_count():
    keys, credentials = _validators()
    committee = list(keys)
    credentials[committee[0]] = ValidatorCredential(
        public_key=credentials[committee[0]].public_key,
        valid_until=NOW + timedelta(days=1),
        revoked=True,
    )
    credentials[committee[1]] = ValidatorCredential(
        public_key=credentials[committee[1]].public_key,
        valid_until=NOW - timedelta(seconds=1),
    )
    certificate = _sign(_certificate(committee), keys, committee[:5])
    result = _validate(certificate, credentials, committee)
    assert not result.valid
    assert result.valid_signatures == 3


def test_l0_cannot_receive_relay_capability_even_with_signatures():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _sign(
        _certificate(committee, level=0, capabilities=("relay",)),
        keys,
        committee[:5],
    )
    result = _validate(certificate, credentials, committee)
    assert not result.valid
    assert result.reason == "level is not eligible for requested capability"


def test_unsigned_capability_is_rejected():
    keys, credentials = _validators()
    committee = list(keys)
    result = _validate(_certificate(committee), credentials, committee)
    assert not result.valid
    assert result.valid_signatures == 0


def test_old_epoch_is_rejected_as_rollback():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _sign(_certificate(committee, epoch=9), keys, committee[:5])
    result = _validate(certificate, credentials, committee, minimum_epoch=10)
    assert not result.valid
    assert result.reason == "capability certificate rollback detected"


def test_malformed_mixed_type_capabilities_fail_closed_without_exception():
    keys, credentials = _validators()
    committee = list(keys)
    certificate = _certificate(committee)
    certificate["capabilities"] = ["relay", 7]
    result = _validate(certificate, credentials, committee)
    assert not result.valid
    assert result.reason == "invalid capabilities"
