from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.node_identity import issue_operational_certificate
from shared.security.operational_credential_state import (
    issue_operational_credential_state,
    operational_credential_genesis_hash,
    operational_credential_state_hash,
    validate_operational_credential_state,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _certificate(root, operational, issued_at=None, valid_until=None):
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=issued_at or NOW - timedelta(minutes=1),
        valid_until=valid_until or NOW + timedelta(days=1),
    )


def test_root_signed_credential_chain_is_monotonic_and_valid():
    root = SigningKey.generate()
    first = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=_certificate(root, SigningKey.generate()),
        credential_epoch=0,
    )
    second = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=_certificate(root, SigningKey.generate()),
        credential_epoch=1,
        previous_state_hash=operational_credential_state_hash(first),
    )

    assert first["previous_state_hash"] == operational_credential_genesis_hash(first["node_id"])
    assert validate_operational_credential_state(first, now=NOW).valid
    assert validate_operational_credential_state(
        second,
        now=NOW,
        expected_node_id=first["node_id"],
        expected_epoch=1,
        expected_previous_hash=operational_credential_state_hash(first),
    ).valid


def test_epoch_previous_hash_certificate_and_signature_tamper_fail_closed():
    root = SigningKey.generate()
    state = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=_certificate(root, SigningKey.generate()),
        credential_epoch=0,
    )
    mutations = []
    changed_epoch = dict(state)
    changed_epoch["credential_epoch"] = 1
    mutations.append(changed_epoch)
    changed_previous = dict(state)
    changed_previous["previous_state_hash"] = "0" * 64
    mutations.append(changed_previous)
    changed_certificate = dict(state)
    changed_certificate["operational_certificate"] = dict(state["operational_certificate"])
    changed_certificate["operational_certificate"]["serial"] = (
        "00000000-0000-0000-0000-000000000000"
    )
    mutations.append(changed_certificate)
    changed_signature = dict(state)
    changed_signature["signature"] = "invalid"
    mutations.append(changed_signature)

    assert all(
        not validate_operational_credential_state(item, now=NOW).valid
        for item in mutations
    )


def test_historical_validation_is_separate_from_live_admission():
    root = SigningKey.generate()
    expired = _certificate(
        root,
        SigningKey.generate(),
        issued_at=NOW - timedelta(days=2),
        valid_until=NOW - timedelta(days=1),
    )
    state = issue_operational_credential_state(
        root_signing_key=root,
        operational_certificate=expired,
        credential_epoch=0,
    )

    live = validate_operational_credential_state(state, now=NOW)
    historical = validate_operational_credential_state(
        state,
        now=NOW,
        require_current_certificate=False,
    )
    assert not live.valid
    assert "not current" in live.reason
    assert historical.valid
