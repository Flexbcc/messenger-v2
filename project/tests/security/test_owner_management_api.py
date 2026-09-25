import base64
import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient
from nacl.signing import SigningKey

from shared.security.keys import public_key_b64
from shared.security.owner_management import sign_owner_request


MODULE_PATH = (
    Path(__file__).parents[2] / "services" / "management-node" / "app" / "main.py"
)


def _load_app(tmp_path):
    spec = importlib.util.spec_from_file_location("ouo_management_api_test", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT_KEY_PATH = str(tmp_path / "node-root.key")
    module.STATE_PATH = str(tmp_path / "owner-state.json")
    module.get_store.cache_clear()
    return module


def _header(request):
    raw = json.dumps(request, sort_keys=True, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def test_pair_status_list_and_revoke_round_trip(tmp_path):
    module = _load_app(tmp_path)
    device = SigningKey.generate()
    now = datetime.now(timezone.utc)
    pairing = module.get_store().create_pairing(role="owner", now=now)

    with TestClient(module.app) as client:
        health = client.get("/health")
        assert health.status_code == 200
        assert health.json()["web_panel"] is False
        assert client.get("/owner/v1/status").status_code == 401

        paired = client.post(
            "/owner/v1/pair",
            json={
                "pairing_id": pairing["pairing_id"],
                "pairing_secret": pairing["pairing_secret"],
                "device_public_key": public_key_b64(device),
            },
        )
        assert paired.status_code == 201
        certificate = paired.json()["certificate"]

        status_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="status-1",
            sequence=0,
            method="GET",
            path="/owner/v1/status",
            body=b"",
        )
        status = client.get(
            "/owner/v1/status",
            headers={"X-OUO-Owner-Request": _header(status_request)},
        )
        assert status.status_code == 200
        assert status.json()["node_id"] == certificate["node_id"]

        revoke_path = f"/owner/v1/devices/{certificate['serial']}/revoke"
        revoke_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="revoke-1",
            sequence=1,
            method="POST",
            path=revoke_path,
            body=b"",
        )
        revoked = client.post(
            revoke_path,
            content=b"",
            headers={"X-OUO-Owner-Request": _header(revoke_request)},
        )
        assert revoked.status_code == 200

        after_revoke_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="status-2",
            sequence=2,
            method="GET",
            path="/owner/v1/status",
            body=b"",
        )
        rejected = client.get(
            "/owner/v1/status",
            headers={"X-OUO-Owner-Request": _header(after_revoke_request)},
        )
        assert rejected.status_code == 401
        assert rejected.json()["detail"] == "certificate revoked"


def test_pairing_errors_do_not_reveal_secret_state(tmp_path):
    module = _load_app(tmp_path)
    pairing = module.get_store().create_pairing(
        role="viewer", now=datetime.now(timezone.utc)
    )
    with TestClient(module.app) as client:
        rejected = client.post(
            "/owner/v1/pair",
            json={
                "pairing_id": pairing["pairing_id"],
                "pairing_secret": "x" * 43,
                "device_public_key": public_key_b64(SigningKey.generate()),
            },
        )
        assert rejected.status_code == 401
        assert rejected.json()["detail"] == "pairing capability rejected"
