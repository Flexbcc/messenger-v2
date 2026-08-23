from datetime import datetime, timedelta, timezone
import json

from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    add_validator_signature,
    build_capability_certificate,
    capability_certificate_hash,
)
from shared.security.capability_enrollment import (
    evaluate_capability_report,
    parse_capability_authority_state,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import node_id_from_root_public_key


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _authority():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    state = parse_capability_authority_state(
        {
            "epoch": 10,
            "committee": sorted(keys),
            "threshold": 5,
            "validators": {
                validator_id: {
                    "public_key": public_key_b64(key),
                    "valid_until": "2026-08-21T12:00:00Z",
                    "revoked": False,
                }
                for validator_id, key in keys.items()
            },
        }
    )
    return keys, state


def _signed_certificate(keys, subject, *, epoch=10, previous_hash=None, max_connections=50):
    certificate = build_capability_certificate(
        subject_node_id=subject,
        level=2,
        capabilities=["relay"],
        quotas={"max_connections": max_connections},
        epoch=epoch,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=1),
        committee=sorted(keys),
        threshold=5,
        previous_hash=previous_hash,
    )
    for validator_id in sorted(keys)[:5]:
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return certificate


def test_report_exposes_verified_capabilities_separately():
    keys, authority = _authority()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    report = evaluate_capability_report(
        _signed_certificate(keys, subject),
        mode="report",
        now=NOW,
        identity_node_id=subject,
        authority_state=authority,
    )
    assert report.status == "valid"
    assert report.certified_capabilities == ("relay",)
    assert report.certified_level == 2
    assert report.epoch == 10


def test_report_rejects_certificate_for_other_node_identity():
    keys, authority = _authority()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    other = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    report = evaluate_capability_report(
        _signed_certificate(keys, subject),
        mode="report",
        now=NOW,
        identity_node_id=other,
        authority_state=authority,
    )
    assert report.status == "invalid"
    assert report.detail == "capability subject does not match Node Identity"


def test_report_does_not_trust_certificate_without_authority_state():
    keys, _ = _authority()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    report = evaluate_capability_report(
        _signed_certificate(keys, subject),
        mode="report",
        now=NOW,
        identity_node_id=subject,
        authority_state=None,
    )
    assert report.status == "unverifiable"
    assert report.certified_capabilities == ()


def test_same_epoch_capability_equivocation_is_rejected():
    keys, authority = _authority()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    stored = _signed_certificate(keys, subject)
    conflicting = _signed_certificate(keys, subject, max_connections=51)
    report = evaluate_capability_report(
        conflicting,
        mode="enforce",
        now=NOW,
        identity_node_id=subject,
        authority_state=authority,
        minimum_epoch=10,
        existing_certificate_json=json.dumps(stored),
    )
    assert report.status == "equivocation"


def test_capability_update_must_extend_stored_hash_chain():
    keys, authority = _authority()
    subject = node_id_from_root_public_key(bytes(SigningKey.generate().verify_key))
    stored = _signed_certificate(keys, subject)
    broken = _signed_certificate(keys, subject, epoch=11)
    report = evaluate_capability_report(
        broken,
        mode="enforce",
        now=NOW,
        identity_node_id=subject,
        authority_state=authority,
        minimum_epoch=10,
        existing_certificate_json=json.dumps(stored),
    )
    assert report.status == "broken_chain"

    chained = _signed_certificate(
        keys,
        subject,
        epoch=11,
        previous_hash=capability_certificate_hash(stored),
    )
    accepted = evaluate_capability_report(
        chained,
        mode="enforce",
        now=NOW,
        identity_node_id=subject,
        authority_state=authority,
        minimum_epoch=10,
        existing_certificate_json=json.dumps(stored),
    )
    assert accepted.status == "valid"
