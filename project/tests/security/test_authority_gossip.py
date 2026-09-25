from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.authority_gossip import (
    issue_authority_announcement,
    validate_authority_announcement,
)
from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import public_key_b64
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


def test_operational_signature_binds_source_epoch_and_checkpoint_hash():
    source_id, key, credential = _source()
    digest = "a" * 64
    announcement = issue_authority_announcement(
        source_node_id=source_id,
        authority_epoch=12,
        checkpoint_hash=digest,
        announced_at=NOW,
        expires_at=NOW + timedelta(minutes=5),
        source_signing_key=key,
    )
    result = validate_authority_announcement(
        announcement,
        now=NOW,
        expected_checkpoint_hash=digest,
        expected_authority_epoch=12,
        source_credential=credential,
    )
    assert result.valid

    tampered = dict(announcement)
    tampered["authority_epoch"] = 13
    result = validate_authority_announcement(
        tampered,
        now=NOW,
        expected_checkpoint_hash=digest,
        expected_authority_epoch=13,
        source_credential=credential,
    )
    assert not result.valid
    assert result.reason == "invalid source announcement signature"


def test_wrong_or_expired_source_credential_is_rejected():
    source_id, key, credential = _source()
    digest = "b" * 64
    announcement = issue_authority_announcement(
        source_node_id=source_id,
        authority_epoch=4,
        checkpoint_hash=digest,
        announced_at=NOW,
        expires_at=NOW + timedelta(minutes=1),
        source_signing_key=key,
    )
    wrong = ValidatorCredential(
        public_key=public_key_b64(SigningKey.generate()),
        valid_until=credential.valid_until,
    )
    assert not validate_authority_announcement(
        announcement,
        now=NOW,
        expected_checkpoint_hash=digest,
        expected_authority_epoch=4,
        source_credential=wrong,
    ).valid
    expired = ValidatorCredential(
        public_key=credential.public_key,
        valid_until=NOW - timedelta(seconds=1),
    )
    result = validate_authority_announcement(
        announcement,
        now=NOW,
        expected_checkpoint_hash=digest,
        expected_authority_epoch=4,
        source_credential=expired,
    )
    assert not result.valid
    assert result.reason == "source credential has expired"
