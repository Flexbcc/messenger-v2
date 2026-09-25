from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.node_identity import issue_operational_certificate
from shared.security.node_identity_enrollment import evaluate_node_identity_report
from shared.security.canonical import canonical_json


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _certificate(root=None, operational=None):
    root = root or SigningKey.generate()
    operational = operational or SigningKey.generate()
    return issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=1),
    )


def test_report_mode_marks_missing_certificate_absent_without_binding():
    report = evaluate_node_identity_report(None, mode="report", now=NOW)
    assert report.status == "absent"
    assert report.identity_node_id is None


def test_report_mode_accepts_valid_certificate_and_binds_operational_key():
    certificate = _certificate()
    report = evaluate_node_identity_report(certificate, mode="report", now=NOW)
    assert report.status == "valid"
    assert report.identity_node_id == certificate["node_id"]
    assert report.operational_public_key == certificate["operational_public_key"]


def test_report_mode_detects_tampering():
    certificate = _certificate()
    certificate["serial"] = "00000000-0000-0000-0000-000000000000"
    report = evaluate_node_identity_report(certificate, mode="report", now=NOW)
    assert report.status == "invalid"
    assert report.detail == "invalid root signature"


def test_existing_alias_cannot_silently_change_root_identity():
    first = _certificate()
    second = _certificate()
    report = evaluate_node_identity_report(
        second,
        mode="report",
        now=NOW,
        existing_identity_node_id=first["node_id"],
    )
    assert report.status == "conflict"
    assert report.identity_node_id == first["node_id"]
    assert report.operational_certificate_json is None


def test_advertised_signing_key_must_match_certified_operational_key():
    certificate = _certificate()
    other_key = _certificate()["operational_public_key"]
    report = evaluate_node_identity_report(
        certificate,
        mode="report",
        now=NOW,
        advertised_signing_public_key=other_key,
    )
    assert report.status == "key_mismatch"


def test_operational_certificate_rotation_rejects_highest_seen_rollback():
    root = SigningKey.generate()
    older = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=NOW - timedelta(minutes=2),
        valid_until=NOW + timedelta(hours=12),
    )
    newer = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=SigningKey.generate().verify_key,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(hours=12),
    )
    accepted = evaluate_node_identity_report(
        newer,
        mode="report",
        now=NOW,
        existing_identity_node_id=older["node_id"],
        existing_operational_certificate_json=canonical_json(older),
    )
    assert accepted.status == "valid"

    rollback = evaluate_node_identity_report(
        older,
        mode="report",
        now=NOW,
        existing_identity_node_id=newer["node_id"],
        existing_operational_certificate_json=canonical_json(newer),
    )
    assert rollback.status == "rollback"
    assert rollback.operational_certificate_json is None


def test_off_mode_does_not_process_certificate():
    report = evaluate_node_identity_report({"untrusted": "data"}, mode="off", now=NOW)
    assert report.status == "skipped"
