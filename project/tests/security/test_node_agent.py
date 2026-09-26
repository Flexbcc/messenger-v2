import hashlib
import hmac
import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).parents[2] / "scripts" / "ouo-node-agent.py"


def _load_agent():
    spec = importlib.util.spec_from_file_location("ouo_node_agent_test", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _signed_action(action, service, secret, config=None):
    payload = {
        "version": 1,
        "action_id": "12345678-1234-4234-8234-123456789abc",
        "action": action,
        "service": service,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if config is not None:
        payload["config"] = config
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    payload["signature"] = hmac.new(secret.encode(), canonical, hashlib.sha256).hexdigest()
    return payload


def test_agent_accepts_only_fixed_restart_and_update_commands(tmp_path):
    module = _load_agent()
    secret = "s" * 32
    install = tmp_path / "project"
    scripts = install / "scripts"
    scripts.mkdir(parents=True)
    updater = scripts / "apply-signed-node-update.sh"
    updater.write_text("#!/bin/sh\n", encoding="utf-8")

    restart = module._validate(_signed_action("service.restart", "home-node", secret), secret)
    update = module._validate(_signed_action("node.update", "node", secret), secret)
    config = module._validate(
        _signed_action(
            "config.apply",
            "node",
            secret,
            {"roles": ["management", "relay"]},
        ),
        secret,
    )

    with patch.object(module.subprocess, "run") as run:
        run.return_value.returncode = 0
        run.return_value.stderr = ""
        run.return_value.stdout = "ok"
        module._execute(restart, install)
        assert run.call_args.args[0] == ["docker", "compose", "restart", "home-node"]
        module._execute(update, install)
        assert run.call_args.args[0] == [str(updater)]
        module._execute(config, install)
        assert run.call_args_list[-2].args[0] == [
            "docker", "compose", "up", "-d", "--no-deps",
            "management-node", "relay-node",
        ]
        assert run.call_args_list[-1].args[0][:3] == ["docker", "compose", "stop"]

    rejected = _signed_action("service.restart", "../../shell", secret)
    try:
        module._validate(rejected, secret)
    except ValueError as exc:
        assert "not allowed" in str(exc)
    else:
        raise AssertionError("unexpected action accepted")
