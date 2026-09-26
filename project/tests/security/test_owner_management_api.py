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
    module.RUNTIME_CONFIG_PATH = str(tmp_path / "runtime-config.json")
    module.AUDIT_PATH = str(tmp_path / "owner-audit.jsonl")
    module.GATEWAY_INTERNAL_URL = ""
    module.GATEWAY_INVITE_SECRET = ""
    module.AGENT_SPOOL_PATH = str(tmp_path / "agent")
    module.AGENT_SECRET = "a" * 32
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
        assert status.json()["roles"]
        assert status.json()["resources"]["disk"]["total_bytes"] > 0

        diagnostics_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="diagnostics-1",
            sequence=1,
            method="GET",
            path="/owner/v1/diagnostics",
            body=b"",
        )
        diagnostics = client.get(
            "/owner/v1/diagnostics",
            headers={"X-OUO-Owner-Request": _header(diagnostics_request)},
        )
        assert diagnostics.status_code == 200
        assert diagnostics.json()["checks"]

        config_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="config-get-1",
            sequence=2,
            method="GET",
            path="/owner/v1/config",
            body=b"",
        )
        config = client.get(
            "/owner/v1/config",
            headers={"X-OUO-Owner-Request": _header(config_request)},
        )
        assert config.status_code == 200
        updated_config = {
            **config.json(),
            "roles": ["home", "management", "relay"],
            "transit_enabled": True,
        }
        update_body = json.dumps(updated_config, separators=(",", ":")).encode()
        update_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="config-put-1",
            sequence=3,
            method="PUT",
            path="/owner/v1/config",
            body=update_body,
        )
        updated = client.put(
            "/owner/v1/config",
            content=update_body,
            headers={
                "X-OUO-Owner-Request": _header(update_request),
                "Content-Type": "application/json",
            },
        )
        assert updated.status_code == 200
        assert "relay" in updated.json()["config"]["roles"]
        assert updated.json()["restart_required"] is True

        audit_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="audit-1",
            sequence=4,
            method="GET",
            path="/owner/v1/audit",
            body=b"",
        )
        audit = client.get(
            "/owner/v1/audit",
            headers={"X-OUO-Owner-Request": _header(audit_request)},
        )
        assert audit.status_code == 200
        assert audit.json()["events"][0]["action"] == "config.updated"

        backup_path = "/owner/v1/config/backup"
        backup_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="backup-1",
            sequence=5,
            method="GET",
            path=backup_path,
            body=b"",
        )
        backup = client.get(
            backup_path,
            headers={"X-OUO-Owner-Request": _header(backup_request)},
        )
        assert backup.status_code == 200
        assert backup.json()["protocol_version"] == "ouo-owner-config-backup/1"
        assert backup.json()["node_id"] == certificate["node_id"]

        restore_path = "/owner/v1/config/restore"
        restore_body = json.dumps(
            {"backup": backup.json()}, separators=(",", ":")
        ).encode()
        restore_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="restore-1",
            sequence=6,
            method="POST",
            path=restore_path,
            body=restore_body,
        )
        restored = client.post(
            restore_path,
            content=restore_body,
            headers={
                "X-OUO-Owner-Request": _header(restore_request),
                "Content-Type": "application/json",
            },
        )
        assert restored.status_code == 200
        assert restored.json()["config"]["transit_enabled"] is True

        update_path = "/owner/v1/updates/apply"
        update_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="update-1",
            sequence=7,
            method="POST",
            path=update_path,
            body=b"",
        )
        update = client.post(
            update_path,
            content=b"",
            headers={"X-OUO-Owner-Request": _header(update_request)},
        )
        assert update.status_code == 202

        restart_path = "/owner/v1/services/home-node/restart"
        restart_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="restart-1",
            sequence=8,
            method="POST",
            path=restart_path,
            body=b"",
        )
        restart = client.post(
            restart_path,
            content=b"",
            headers={"X-OUO-Owner-Request": _header(restart_request)},
        )
        assert restart.status_code == 202
        action_id = restart.json()["action_id"]
        action_path = f"/owner/v1/actions/{action_id}"
        action_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="action-1",
            sequence=9,
            method="GET",
            path=action_path,
            body=b"",
        )
        action = client.get(
            action_path,
            headers={"X-OUO-Owner-Request": _header(action_request)},
        )
        assert action.status_code == 200
        assert action.json()["status"] == "pending"

        revoke_path = f"/owner/v1/devices/{certificate['serial']}/revoke"
        revoke_request = sign_owner_request(
            device_signing_key=device,
            certificate_serial=certificate["serial"],
            timestamp=datetime.now(timezone.utc),
            nonce="revoke-1",
            sequence=10,
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
            sequence=11,
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
