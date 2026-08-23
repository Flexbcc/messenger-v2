from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import public_key_b64
from shared.security.node_advertisement_observation import (
    issue_advertisement_observation,
    validate_advertisement_observation,
)
from shared.security.node_identity import node_id_from_root_public_key


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _source():
    root = SigningKey.generate()
    operational = SigningKey.generate()
    return (
        node_id_from_root_public_key(bytes(root.verify_key)),
        operational,
        ValidatorCredential(
            public_key=public_key_b64(operational),
            valid_until=NOW + timedelta(days=1),
        ),
    )


def test_observation_signature_binds_subject_epoch_and_hash():
    source_id, key, credential = _source()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    digest = "a" * 64
    observation = issue_advertisement_observation(
        source_node_id=source_id,
        subject_node_id=subject,
        advertisement_epoch=8,
        advertisement_hash=digest,
        observed_at=NOW,
        expires_at=NOW + timedelta(minutes=5),
        source_signing_key=key,
    )
    assert validate_advertisement_observation(
        observation,
        now=NOW,
        expected_subject_node_id=subject,
        expected_advertisement_epoch=8,
        expected_advertisement_hash=digest,
        source_credential=credential,
    ).valid

    tampered = dict(observation)
    tampered["advertisement_epoch"] = 9
    result = validate_advertisement_observation(
        tampered,
        now=NOW,
        expected_subject_node_id=subject,
        expected_advertisement_epoch=9,
        expected_advertisement_hash=digest,
        source_credential=credential,
    )
    assert not result.valid
    assert result.reason == "invalid source observation signature"


def test_expired_or_revoked_observer_credential_is_rejected():
    source_id, key, credential = _source()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    observation = issue_advertisement_observation(
        source_node_id=source_id,
        subject_node_id=subject,
        advertisement_epoch=1,
        advertisement_hash="b" * 64,
        observed_at=NOW,
        expires_at=NOW + timedelta(minutes=1),
        source_signing_key=key,
    )
    revoked = ValidatorCredential(
        public_key=credential.public_key,
        valid_until=credential.valid_until,
        revoked=True,
    )
    result = validate_advertisement_observation(
        observation,
        now=NOW,
        expected_subject_node_id=subject,
        expected_advertisement_epoch=1,
        expected_advertisement_hash="b" * 64,
        source_credential=revoked,
    )
    assert not result.valid
    assert result.reason == "source credential is revoked"
