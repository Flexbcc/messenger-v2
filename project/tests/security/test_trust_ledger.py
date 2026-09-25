import hashlib
from datetime import datetime, timedelta, timezone

import pytest
from nacl.signing import SigningKey

from shared.security.capability_certificate import ValidatorCredential
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.trust_ledger import (
    TrustLedgerConflict,
    TrustLedgerStore,
    add_trust_record_signature,
    build_trust_record,
    equivocation_signers,
    trust_record_hash,
    validate_trust_record,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
SUBJECT = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))


def _authority():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    credentials = {
        validator_id: ValidatorCredential(
            public_key=public_key_b64(key),
            valid_until=NOW + timedelta(days=2),
        )
        for validator_id, key in keys.items()
    }
    return keys, credentials


def _record(
    keys,
    *,
    epoch=1,
    previous_hash=None,
    previous_level=0,
    new_level=1,
    action="promotion",
):
    record = build_trust_record(
        subject_node_id=SUBJECT,
        previous_level=previous_level,
        new_level=new_level,
        action=action,
        epoch=epoch,
        metrics_commitment=hashlib.sha256(f"evidence-{epoch}".encode()).hexdigest(),
        committee=sorted(keys),
        threshold=5,
        previous_hash=previous_hash,
        decided_at=NOW,
    )
    for validator_id in sorted(keys)[:5]:
        record = add_trust_record_signature(
            record,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return record


def _validation(record, credentials, keys):
    return validate_trust_record(
        record,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )


def test_quorum_signed_promotion_is_valid():
    keys, credentials = _authority()
    result = _validation(_record(keys), credentials, keys)
    assert result.valid
    assert result.valid_signatures == 5


def test_four_signatures_cannot_create_trust_record():
    keys, credentials = _authority()
    record = _record(keys)
    record["signatures"] = record["signatures"][:4]
    result = _validation(record, credentials, keys)
    assert not result.valid
    assert result.valid_signatures == 4


def test_invalid_action_semantics_are_rejected_before_quorum():
    keys, credentials = _authority()
    record = _record(keys)
    record["new_level"] = 0
    result = _validation(record, credentials, keys)
    assert not result.valid
    assert result.reason == "promotion must increase level"


def test_ledger_persists_append_only_hash_chain(tmp_path):
    keys, credentials = _authority()
    ledger = TrustLedgerStore(str(tmp_path / "trust.db"))
    first = _record(keys, epoch=1)
    second = _record(
        keys,
        epoch=2,
        previous_hash=trust_record_hash(first),
        previous_level=1,
        new_level=2,
    )

    assert ledger.append_validated(
        first,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    assert ledger.append_validated(
        second,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    assert [record["epoch"] for record in ledger.records(SUBJECT)] == [1, 2]


def test_broken_previous_hash_is_rejected(tmp_path):
    keys, credentials = _authority()
    ledger = TrustLedgerStore(str(tmp_path / "trust.db"))
    first = _record(keys, epoch=1)
    ledger.append_validated(
        first,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    broken = _record(keys, epoch=2, previous_hash="00" * 32, new_level=2)
    with pytest.raises(ValueError, match="previous_hash"):
        ledger.append_validated(
            broken,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )


def test_previous_level_must_match_ledger_head(tmp_path):
    keys, credentials = _authority()
    ledger = TrustLedgerStore(str(tmp_path / "trust.db"))
    first = _record(keys, epoch=1)
    ledger.append_validated(
        first,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    inconsistent = _record(
        keys,
        epoch=2,
        previous_hash=trust_record_hash(first),
        previous_level=0,
        new_level=2,
    )
    with pytest.raises(ValueError, match="previous_level"):
        ledger.append_validated(
            inconsistent,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )


def test_revocation_is_terminal_and_suspension_requires_explicit_reinstatement(tmp_path):
    keys, credentials = _authority()
    revoked_ledger = TrustLedgerStore(str(tmp_path / "revoked.db"))
    revoked = _record(
        keys,
        epoch=1,
        previous_level=2,
        new_level=0,
        action="revocation",
    )
    revoked_ledger.append_validated(
        revoked,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    after_revocation = _record(
        keys,
        epoch=2,
        previous_hash=trust_record_hash(revoked),
        previous_level=0,
        new_level=1,
        action="promotion",
    )
    with pytest.raises(ValueError, match="terminal"):
        revoked_ledger.append_validated(
            after_revocation,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )

    suspended_ledger = TrustLedgerStore(str(tmp_path / "suspended.db"))
    suspended = _record(
        keys,
        epoch=1,
        previous_level=2,
        new_level=2,
        action="suspension",
    )
    suspended_ledger.append_validated(
        suspended,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    after_suspension = _record(
        keys,
        epoch=2,
        previous_hash=trust_record_hash(suspended),
        previous_level=2,
        new_level=3,
        action="promotion",
    )
    with pytest.raises(ValueError, match="only advance"):
        suspended_ledger.append_validated(
            after_suspension,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )

    reinstatement = _record(
        keys,
        epoch=2,
        previous_hash=trust_record_hash(suspended),
        previous_level=2,
        new_level=2,
        action="reinstatement",
    )
    assert suspended_ledger.append_validated(
        reinstatement,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    promotion = _record(
        keys,
        epoch=3,
        previous_hash=trust_record_hash(reinstatement),
        previous_level=2,
        new_level=3,
        action="promotion",
    )
    assert suspended_ledger.append_validated(
        promotion,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )


def test_reinstatement_cannot_be_first_or_follow_non_suspension(tmp_path):
    keys, credentials = _authority()
    ledger = TrustLedgerStore(str(tmp_path / "trust.db"))
    first = _record(
        keys,
        epoch=1,
        previous_level=1,
        new_level=1,
        action="reinstatement",
    )
    with pytest.raises(ValueError, match="preceding suspension"):
        ledger.append_validated(
            first,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )


def test_conflicting_epoch_is_preserved_as_equivocation_evidence(tmp_path):
    keys, credentials = _authority()
    ledger = TrustLedgerStore(str(tmp_path / "trust.db"))
    first = _record(keys, epoch=1, new_level=1)
    conflicting = _record(keys, epoch=1, new_level=2)
    ledger.append_validated(
        first,
        now=NOW,
        expected_committee=sorted(keys),
        expected_threshold=5,
        validator_credentials=credentials,
    )
    with pytest.raises(TrustLedgerConflict):
        ledger.append_validated(
            conflicting,
            now=NOW,
            expected_committee=sorted(keys),
            expected_threshold=5,
            validator_credentials=credentials,
        )
    assert ledger.equivocation_count() == 1
    assert len(equivocation_signers(first, conflicting)) == 5
