from datetime import datetime, timedelta, timezone

import pytest
from nacl.signing import SigningKey

from shared.security.node_identity import (
    NODE_ID_PREFIX,
    issue_operational_certificate,
    node_id_from_root_public_key,
    validate_operational_certificate,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _certificate(root=None, operational=None, **kwargs):
    root = root or SigningKey.generate()
    operational = operational or SigningKey.generate()
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=kwargs.get("issued_at", NOW - timedelta(minutes=1)),
        valid_until=kwargs.get("valid_until", NOW + timedelta(days=1)),
        serial=kwargs.get("serial"),
    )


def test_node_id_is_stable_and_self_certifying():
    root = SigningKey.generate()
    first = node_id_from_root_public_key(bytes(root.verify_key))
    second = node_id_from_root_public_key(bytes(root.verify_key))
    assert first == second
    assert first.startswith(NODE_ID_PREFIX)
    assert len(first) == len(NODE_ID_PREFIX) + 52


def test_valid_operational_certificate_is_accepted():
    result = validate_operational_certificate(_certificate(), now=NOW)
    assert result.valid
    assert result.reason is None


def test_operational_rotation_preserves_node_id():
    root = SigningKey.generate()
    first = _certificate(root=root, operational=SigningKey.generate())
    second = _certificate(root=root, operational=SigningKey.generate())
    assert first["node_id"] == second["node_id"]
    assert first["operational_public_key"] != second["operational_public_key"]
    assert validate_operational_certificate(first, now=NOW).valid
    assert validate_operational_certificate(second, now=NOW).valid


def test_tampered_operational_key_is_rejected():
    certificate = _certificate()
    certificate["operational_public_key"] = _certificate()["operational_public_key"]
    result = validate_operational_certificate(certificate, now=NOW)
    assert not result.valid
    assert result.reason == "invalid root signature"


def test_node_id_must_match_root_public_key():
    certificate = _certificate()
    certificate["node_id"] = node_id_from_root_public_key(
        bytes(SigningKey.generate().verify_key)
    )
    result = validate_operational_certificate(certificate, now=NOW)
    assert not result.valid
    assert result.reason == "node_id does not match root public key"


def test_expired_certificate_is_rejected():
    certificate = _certificate(
        issued_at=NOW - timedelta(days=2),
        valid_until=NOW - timedelta(hours=1),
    )
    result = validate_operational_certificate(
        certificate, now=NOW, clock_skew=timedelta(0)
    )
    assert not result.valid
    assert result.reason == "certificate has expired"


def test_not_yet_valid_certificate_is_rejected():
    certificate = _certificate(
        issued_at=NOW + timedelta(hours=1),
        valid_until=NOW + timedelta(days=1),
    )
    result = validate_operational_certificate(
        certificate, now=NOW, clock_skew=timedelta(0)
    )
    assert not result.valid
    assert result.reason == "certificate is not yet valid"


def test_issuer_refuses_certificate_longer_than_seven_days():
    with pytest.raises(ValueError, match="exceeds 7 days"):
        _certificate(valid_until=NOW + timedelta(days=8))


def test_issuer_refuses_naive_timestamp():
    with pytest.raises(ValueError, match="timezone-aware"):
        _certificate(issued_at=NOW.replace(tzinfo=None))


def test_issuer_refuses_noncanonical_serial():
    with pytest.raises(ValueError, match="canonical UUID"):
        _certificate(serial="NOT-A-UUID")


def test_unknown_field_is_rejected_fail_closed():
    certificate = _certificate()
    certificate["future_critical_field"] = True
    result = validate_operational_certificate(certificate, now=NOW)
    assert not result.valid
    assert result.reason == "invalid certificate fields"
