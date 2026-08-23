import hashlib
from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.operational_credential_revocation import (
    add_operational_credential_revocation_signature,
    build_operational_credential_revocation,
    operational_credential_revocation_genesis_hash,
    operational_credential_revocation_hash,
    validate_operational_credential_revocation,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _fixture():
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(hours=1),
        valid_until=NOW + timedelta(days=1),
    )
    validator_keys = {
        f"validator-{index}": SigningKey.generate() for index in range(7)
    }
    credentials = {
        validator_id: ValidatorCredential(
            public_key=public_key_b64(key),
            valid_until=NOW + timedelta(days=2),
        )
        for validator_id, key in validator_keys.items()
    }
    return certificate, validator_keys, credentials


def _revocation(certificate, validator_keys, *, epoch=0, previous_hash=None):
    revocation = build_operational_credential_revocation(
        operational_certificate=certificate,
        credential_epoch=3,
        revocation_epoch=epoch,
        authority_epoch=11,
        reason_commitment=hashlib.sha256(b"incident-42").hexdigest(),
        committee=sorted(validator_keys),
        threshold=5,
        decided_at=NOW,
        previous_hash=previous_hash,
    )
    for validator_id in sorted(validator_keys)[:5]:
        revocation = add_operational_credential_revocation_signature(
            revocation,
            validator_id=validator_id,
            validator_signing_key=validator_keys[validator_id],
        )
    return revocation


def _validate(revocation, certificate, validator_keys, credentials, *, epoch=0, previous=None):
    return validate_operational_credential_revocation(
        revocation,
        operational_certificate=certificate,
        now=NOW,
        expected_revocation_epoch=epoch,
        expected_previous_hash=(
            previous
            or operational_credential_revocation_genesis_hash(certificate["node_id"])
        ),
        expected_committee=sorted(validator_keys),
        expected_threshold=5,
        validator_credentials=credentials,
        expected_authority_epoch=11,
    )


def test_five_of_seven_can_revoke_one_operational_certificate():
    certificate, keys, credentials = _fixture()
    revocation = _revocation(certificate, keys)

    result = _validate(revocation, certificate, keys, credentials)

    assert result.valid
    assert result.valid_signatures == 5
    assert revocation["effective_at"] == revocation["decided_at"]


def test_four_of_seven_cannot_revoke_operational_certificate():
    certificate, keys, credentials = _fixture()
    revocation = _revocation(certificate, keys)
    revocation["signatures"] = revocation["signatures"][:4]

    result = _validate(revocation, certificate, keys, credentials)

    assert not result.valid
    assert result.valid_signatures == 4


def test_revocation_is_bound_to_exact_serial_key_and_certificate_hash():
    certificate, keys, credentials = _fixture()
    revocation = _revocation(certificate, keys)
    other = dict(certificate)
    other["serial"] = "00000000-0000-0000-0000-000000000000"

    result = _validate(revocation, other, keys, credentials)

    assert not result.valid
    assert "does not match" in result.reason


def test_v1_rejects_retroactive_or_delayed_effective_time():
    certificate, keys, credentials = _fixture()
    revocation = _revocation(certificate, keys)
    revocation["effective_at"] = (
        NOW - timedelta(minutes=1)
    ).isoformat().replace("+00:00", "Z")

    result = _validate(revocation, certificate, keys, credentials)

    assert not result.valid
    assert "cannot be retroactive" in result.reason


def test_revocation_chain_requires_exact_epoch_and_previous_hash():
    certificate, keys, credentials = _fixture()
    first = _revocation(certificate, keys)
    second = _revocation(
        certificate,
        keys,
        epoch=1,
        previous_hash=operational_credential_revocation_hash(first),
    )

    valid = _validate(
        second,
        certificate,
        keys,
        credentials,
        epoch=1,
        previous=operational_credential_revocation_hash(first),
    )
    wrong_epoch = _validate(second, certificate, keys, credentials)

    assert valid.valid
    assert not wrong_epoch.valid


def test_revocation_does_not_mutate_node_level_or_capabilities_by_design():
    certificate, keys, credentials = _fixture()
    revocation = _revocation(certificate, keys)

    assert _validate(revocation, certificate, keys, credentials).valid
    assert "level" not in revocation
    assert "capabilities" not in revocation
    assert revocation["node_id"] == certificate["node_id"]
