from datetime import datetime, timedelta, timezone
import json

from nacl.signing import SigningKey

from shared.security.node_advertisement import issue_node_advertisement
from shared.security.node_advertisement_enrollment import (
    evaluate_node_advertisement_report,
)
from shared.security.node_identity import issue_operational_certificate


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _advertisement(endpoint="https://home.example", epoch=10):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(minutes=2),
        valid_until=NOW + timedelta(days=1),
    )
    advertisement = issue_node_advertisement(
        operational_signing_key=operational,
        operational_certificate=certificate,
        endpoints=[endpoint],
        supported_transports=["https"],
        supported_protocols=["ouo-federation-envelope/1"],
        epoch=epoch,
        issued_at=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(hours=1),
    )
    return advertisement, certificate


def test_report_mode_accepts_bound_signed_endpoint():
    advertisement, certificate = _advertisement()
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=NOW,
        identity_node_id=certificate["node_id"],
        advertised_node_url="https://home.example",
        minimum_epoch=10,
    )
    assert report.status == "valid"
    assert report.epoch == 10
    assert report.endpoints == ("https://home.example",)


def test_advertisement_requires_prevalidated_identity_binding():
    advertisement, _ = _advertisement()
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=NOW,
        identity_node_id=None,
        advertised_node_url="https://home.example",
    )
    assert report.status == "unverifiable"


def test_registration_url_must_be_covered_by_signature():
    advertisement, certificate = _advertisement()
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=NOW,
        identity_node_id=certificate["node_id"],
        advertised_node_url="https://evil.example",
    )
    assert report.status == "endpoint_mismatch"


def test_old_advertisement_cannot_roll_back_epoch():
    advertisement, certificate = _advertisement(epoch=9)
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=NOW,
        identity_node_id=certificate["node_id"],
        advertised_node_url="https://home.example",
        minimum_epoch=10,
    )
    assert report.status == "invalid"
    assert report.detail == "invalid or stale advertisement epoch"


def test_different_advertisement_at_same_epoch_is_equivocation():
    advertisement, certificate = _advertisement(epoch=10)
    conflicting = dict(advertisement)
    conflicting["advertisement_id"] = "00000000-0000-4000-8000-000000000001"
    # Stored advertisements reached this comparison only after validation; the
    # helper must nevertheless refuse a different content hash at the same epoch.
    report = evaluate_node_advertisement_report(
        advertisement,
        mode="report",
        now=NOW,
        identity_node_id=certificate["node_id"],
        advertised_node_url="https://home.example",
        minimum_epoch=10,
        existing_advertisement_json=json.dumps(conflicting),
    )
    assert report.status == "equivocation"


def test_off_mode_does_not_parse_untrusted_input():
    report = evaluate_node_advertisement_report(
        {"invalid": "input"},
        mode="off",
        now=NOW,
        identity_node_id=None,
        advertised_node_url="https://home.example",
    )
    assert report.status == "skipped"
