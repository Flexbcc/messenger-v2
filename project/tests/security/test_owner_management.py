from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.keys import public_key_b64
from shared.security.owner_management import (
    issue_owner_device_certificate,
    sign_owner_request,
    validate_owner_device_certificate,
    validate_owner_request,
)


NOW = datetime(2026, 9, 24, 12, 0, tzinfo=timezone.utc)


def _certificate(role="operator"):
    root = SigningKey.generate()
    device = SigningKey.generate()
    certificate = issue_owner_device_certificate(
        node_root_signing_key=root,
        device_verify_key=device.verify_key,
        role=role,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=30),
    )
    return root, device, certificate


def test_owner_certificate_is_node_bound_and_revocable():
    root, _, certificate = _certificate()
    assert validate_owner_device_certificate(
        certificate, node_root_public_key=public_key_b64(root), now=NOW
    ).valid

    another_root = SigningKey.generate()
    wrong_node = validate_owner_device_certificate(
        certificate, node_root_public_key=public_key_b64(another_root), now=NOW
    )
    assert not wrong_node.valid

    revoked = validate_owner_device_certificate(
        certificate,
        node_root_public_key=public_key_b64(root),
        now=NOW,
        revoked_serials=frozenset({certificate["serial"]}),
    )
    assert not revoked.valid
    assert revoked.reason == "certificate revoked"


def test_owner_request_binds_method_path_body_and_sequence():
    _, device, certificate = _certificate()
    request = sign_owner_request(
        device_signing_key=device,
        certificate_serial=certificate["serial"],
        timestamp=NOW,
        nonce="nonce-1",
        sequence=7,
        method="POST",
        path="/owner/v1/restart",
        body=b'{"service":"home"}',
    )
    assert validate_owner_request(
        request,
        certificate=certificate,
        now=NOW,
        method="POST",
        path="/owner/v1/restart",
        body=b'{"service":"home"}',
        minimum_sequence=7,
    ).valid

    assert not validate_owner_request(
        request,
        certificate=certificate,
        now=NOW,
        method="POST",
        path="/owner/v1/restart",
        body=b'{"service":"relay"}',
        minimum_sequence=7,
    ).valid
    assert not validate_owner_request(
        request,
        certificate=certificate,
        now=NOW,
        method="POST",
        path="/owner/v1/restart",
        body=b'{"service":"home"}',
        minimum_sequence=8,
    ).valid


def test_owner_request_replay_and_expiry_are_rejected():
    _, device, certificate = _certificate()
    request = sign_owner_request(
        device_signing_key=device,
        certificate_serial=certificate["serial"],
        timestamp=NOW,
        nonce="used-nonce",
        sequence=1,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    replay = validate_owner_request(
        request,
        certificate=certificate,
        now=NOW,
        method="GET",
        path="/owner/v1/health",
        body=b"",
        minimum_sequence=1,
        seen_nonces=frozenset({"used-nonce"}),
    )
    assert not replay.valid
    assert replay.reason == "request nonce already used"

    expired = validate_owner_request(
        request,
        certificate=certificate,
        now=NOW + timedelta(minutes=3),
        method="GET",
        path="/owner/v1/health",
        body=b"",
        minimum_sequence=1,
    )
    assert not expired.valid
    assert expired.reason == "request timestamp outside allowed window"


def test_tampered_role_invalidates_node_signature():
    root, _, certificate = _certificate(role="viewer")
    certificate["role"] = "owner"
    result = validate_owner_device_certificate(
        certificate, node_root_public_key=public_key_b64(root), now=NOW
    )
    assert not result.valid
    assert result.reason == "invalid certificate signature"
