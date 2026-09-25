from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.node_identity import issue_operational_certificate
from shared.security.observer_auth import (
    MAX_PROOF_BYTES,
    issue_observer_request_proof,
    validate_observer_request_proof,
)


def _credential(now):
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=SigningKey.generate(),
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return operational, certificate


def test_portable_observer_proof_binds_node_action_payload_and_certificate():
    now = datetime.now(timezone.utc)
    key, certificate = _credential(now)
    proof = issue_observer_request_proof(
        observer_signing_key=key,
        operational_certificate=certificate,
        action="challenge_assignment_pull",
        payload={"limit": 20},
        issued_at=now,
        expires_at=now + timedelta(minutes=2),
    )
    valid = validate_observer_request_proof(
        proof,
        action="challenge_assignment_pull",
        payload={"limit": 20},
        now=now,
    )
    assert valid.valid
    assert valid.observer_node_id == certificate["node_id"]

    assert not validate_observer_request_proof(
        proof,
        action="challenge_assignment_pull",
        payload={"limit": 21},
        now=now,
    ).valid
    tampered = {**proof, "observer_node_id": "ouo-node-v1-tampered"}
    assert not validate_observer_request_proof(
        tampered,
        action="challenge_assignment_pull",
        payload={"limit": 20},
        now=now,
    ).valid


def test_observer_proof_expiry_and_signature_tamper_fail_closed():
    now = datetime.now(timezone.utc)
    key, certificate = _credential(now)
    proof = issue_observer_request_proof(
        observer_signing_key=key,
        operational_certificate=certificate,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        issued_at=now - timedelta(minutes=10),
        expires_at=now - timedelta(minutes=8),
    )
    assert not validate_observer_request_proof(
        proof,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        now=now,
    ).valid
    fresh = issue_observer_request_proof(
        observer_signing_key=key,
        operational_certificate=certificate,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        issued_at=now,
        expires_at=now + timedelta(minutes=1),
    )
    fresh["signature"] = fresh["signature"][:-2] + "AA"
    assert not validate_observer_request_proof(
        fresh,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        now=now,
    ).valid


def test_oversized_observer_proof_fails_before_certificate_validation():
    now = datetime.now(timezone.utc)
    key, certificate = _credential(now)
    proof = issue_observer_request_proof(
        observer_signing_key=key,
        operational_certificate=certificate,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        issued_at=now,
        expires_at=now + timedelta(minutes=1),
    )
    proof["operational_certificate"]["root_signature"] = "A" * MAX_PROOF_BYTES

    validation = validate_observer_request_proof(
        proof,
        action="challenge_assignment_pull",
        payload={"limit": 1},
        now=now,
    )

    assert not validation.valid
    assert validation.reason == "observer proof exceeds size limit"
