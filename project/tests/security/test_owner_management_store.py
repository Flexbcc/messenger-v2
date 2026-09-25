import json
import stat
from datetime import datetime, timedelta, timezone

import pytest
from nacl.signing import SigningKey

from shared.security.keys import public_key_b64
from shared.security.owner_management import sign_owner_request
from shared.security.owner_management_store import OwnerManagementStore


NOW = datetime(2026, 9, 24, 12, 0, tzinfo=timezone.utc)


def _paired_store(tmp_path, role="operator"):
    root = SigningKey.generate()
    device = SigningKey.generate()
    store = OwnerManagementStore(tmp_path / "owner-state.json", node_root_signing_key=root)
    pairing = store.create_pairing(role=role, now=NOW)
    certificate = store.consume_pairing(
        pairing_id=pairing["pairing_id"],
        pairing_secret=pairing["pairing_secret"],
        device_public_key=public_key_b64(device),
        now=NOW,
    )
    return store, device, certificate, pairing


def test_pairing_is_one_time_and_secret_is_not_persisted(tmp_path):
    store, device, _, pairing = _paired_store(tmp_path)
    state_text = store.path.read_text(encoding="utf-8")
    assert pairing["pairing_secret"] not in state_text
    assert stat.S_IMODE(store.path.stat().st_mode) == 0o600
    with pytest.raises(ValueError, match="unknown or consumed"):
        store.consume_pairing(
            pairing_id=pairing["pairing_id"],
            pairing_secret=pairing["pairing_secret"],
            device_public_key=public_key_b64(device),
            now=NOW,
        )


def test_invalid_device_key_does_not_consume_pairing(tmp_path):
    root = SigningKey.generate()
    store = OwnerManagementStore(tmp_path / "owner-state.json", node_root_signing_key=root)
    pairing = store.create_pairing(role="viewer", now=NOW)
    with pytest.raises(ValueError, match="invalid device public key"):
        store.consume_pairing(
            pairing_id=pairing["pairing_id"],
            pairing_secret=pairing["pairing_secret"],
            device_public_key="not-a-key",
            now=NOW,
        )
    device = SigningKey.generate()
    certificate = store.consume_pairing(
        pairing_id=pairing["pairing_id"],
        pairing_secret=pairing["pairing_secret"],
        device_public_key=public_key_b64(device),
        now=NOW,
    )
    assert certificate["role"] == "viewer"


def test_role_permission_sequence_and_nonce_are_enforced(tmp_path):
    store, device, certificate, _ = _paired_store(tmp_path, role="viewer")
    request = sign_owner_request(
        device_signing_key=device,
        certificate_serial=certificate["serial"],
        timestamp=NOW,
        nonce="request-1",
        sequence=0,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    denied = store.authorize_request(
        request,
        permission="service.restart",
        now=NOW,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    assert not denied.valid
    assert denied.reason == "owner role lacks permission"

    accepted = store.authorize_request(
        request,
        permission="health.read",
        now=NOW,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    assert accepted.valid
    replay = store.authorize_request(
        request,
        permission="health.read",
        now=NOW,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    assert not replay.valid
    assert replay.reason in {"request nonce already used", "request sequence is stale"}


def test_revoked_device_cannot_authorize(tmp_path):
    store, device, certificate, _ = _paired_store(tmp_path)
    assert store.revoke_device(certificate["serial"])
    request = sign_owner_request(
        device_signing_key=device,
        certificate_serial=certificate["serial"],
        timestamp=NOW,
        nonce="request-2",
        sequence=0,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    result = store.authorize_request(
        request,
        permission="health.read",
        now=NOW,
        method="GET",
        path="/owner/v1/health",
        body=b"",
    )
    assert not result.valid
    assert result.reason == "certificate revoked"


def test_expired_pairing_is_removed(tmp_path):
    root = SigningKey.generate()
    store = OwnerManagementStore(tmp_path / "owner-state.json", node_root_signing_key=root)
    pairing = store.create_pairing(
        role="owner", now=NOW, expires_in=timedelta(seconds=10)
    )
    with pytest.raises(ValueError, match="expired"):
        store.consume_pairing(
            pairing_id=pairing["pairing_id"],
            pairing_secret=pairing["pairing_secret"],
            device_public_key=public_key_b64(SigningKey.generate()),
            now=NOW + timedelta(seconds=11),
        )
    state = json.loads(store.path.read_text(encoding="utf-8"))
    assert pairing["pairing_id"] not in state["pairings"]
