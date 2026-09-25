from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.bootstrap_record import (
    issue_bootstrap_record,
    validate_bootstrap_record,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _record(record_version=3):
    key = SigningKey.generate()
    return issue_bootstrap_record(
        identity_signing_key=key,
        identity_version=1,
        ingress_endpoints=["https://ingress-a.example", "wss://ingress-b.example/ws"],
        record_version=record_version,
        issued_at=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(hours=1),
    )


def test_user_signed_bootstrap_record_is_valid():
    assert validate_bootstrap_record(_record(), now=NOW).valid


def test_discovery_cannot_replace_ingress_without_user_signature():
    record = _record()
    record["rendezvous_data"]["ingress_endpoints"] = ["https://evil.example"]
    result = validate_bootstrap_record(record, now=NOW)
    assert not result.valid
    assert result.reason == "invalid identity signature"


def test_identity_key_substitution_changes_self_certifying_user_id():
    record = _record()
    other = _record()
    record["identity_public_key"] = other["identity_public_key"]
    result = validate_bootstrap_record(record, now=NOW)
    assert not result.valid
    assert result.reason == "user_id does not match identity key"


def test_record_version_rollback_is_rejected():
    result = validate_bootstrap_record(
        _record(record_version=2), now=NOW, minimum_record_version=3
    )
    assert not result.valid
    assert result.reason == "invalid or stale record_version"


def test_expired_record_is_rejected():
    record = _record()
    result = validate_bootstrap_record(record, now=NOW + timedelta(hours=2))
    assert not result.valid
    assert result.reason == "record has expired"


def test_extra_critical_shape_is_fail_closed():
    record = _record()
    record["discovery_override"] = True
    result = validate_bootstrap_record(record, now=NOW)
    assert not result.valid
    assert result.reason == "invalid record fields"
