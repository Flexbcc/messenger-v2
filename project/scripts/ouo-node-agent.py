#!/usr/bin/env python3
"""Execute authenticated owner actions without exposing a shell or Docker socket.

Management API writes HMAC-authenticated files into a shared spool. This host
agent accepts only a fixed action/service allowlist and invokes commands without
``shell=True``. It can run continuously under systemd or once from a timer.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


ALLOWED_SERVICES = frozenset(
    {
        "home-node",
        "relay-node",
        "storage-node",
        "discovery-node",
        "gateway-node",
        "management-node",
    }
)
SERVICE_BY_ROLE = {
    "home": "home-node",
    "relay": "relay-node",
    "storage": "storage-node",
    "discovery": "discovery-node",
    "gateway": "gateway-node",
    "management": "management-node",
}
MAX_ACTION_AGE = timedelta(minutes=5)


def _parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(timezone.utc)


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(value, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _validate(raw: dict[str, Any], secret: str) -> dict[str, Any]:
    expected = {"version", "action_id", "action", "service", "created_at", "signature"}
    if raw.get("action") == "config.apply":
        expected.add("config")
    if set(raw) != expected or raw.get("version") != 1:
        raise ValueError("invalid action fields")
    signature = str(raw["signature"])
    unsigned = {key: raw[key] for key in expected - {"signature"}}
    canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()
    calculated = hmac.new(secret.encode(), canonical, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, calculated):
        raise ValueError("invalid action signature")
    created_at = _parse_time(str(raw["created_at"]))
    age = datetime.now(timezone.utc) - created_at
    if age < timedelta(seconds=-30) or age > MAX_ACTION_AGE:
        raise ValueError("action is stale")
    allowed = (
        raw["action"] == "service.restart" and raw["service"] in ALLOWED_SERVICES
    ) or (raw["action"] == "node.update" and raw["service"] == "node")
    if raw["action"] == "config.apply" and raw["service"] == "node":
        config = raw.get("config")
        roles = config.get("roles") if isinstance(config, dict) else None
        allowed = (
            isinstance(roles, list)
            and "management" in roles
            and len(roles) == len(set(roles))
            and all(role in SERVICE_BY_ROLE for role in roles)
        )
    if not allowed:
        raise ValueError("action is not allowed")
    return raw


def _execute(action: dict[str, Any], install_dir: Path) -> dict[str, Any]:
    started = time.monotonic()
    if action["action"] == "service.restart":
        command = ["docker", "compose", "restart", str(action["service"])]
        commands = [command]
    elif action["action"] == "node.update":
        command = [os.fspath(install_dir / "scripts" / "apply-signed-node-update.sh")]
        commands = [command]
    else:
        enabled = {SERVICE_BY_ROLE[role] for role in action["config"]["roles"]}
        disabled = sorted(ALLOWED_SERVICES - enabled)
        commands = [["docker", "compose", "up", "-d", "--no-deps", *sorted(enabled)]]
        if disabled:
            commands.append(["docker", "compose", "stop", *disabled])
    outputs = []
    exit_code = 0
    for command in commands:
        completed = subprocess.run(
            command,
            cwd=install_dir,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
            shell=False,
        )
        outputs.append(completed.stderr or completed.stdout)
        if completed.returncode != 0:
            exit_code = completed.returncode
            break
    return {
        "version": 1,
        "action_id": action["action_id"],
        "action": action["action"],
        "service": action["service"],
        "status": "succeeded" if exit_code == 0 else "failed",
        "exit_code": exit_code,
        "duration_ms": int((time.monotonic() - started) * 1000),
        "finished_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "message": "\n".join(outputs)[-1000:],
    }


def process_once(spool: Path, install_dir: Path, secret: str) -> int:
    requests = spool / "requests"
    results = spool / "results"
    rejected = spool / "rejected"
    for path in sorted(requests.glob("*.json")):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("action must be an object")
            action = _validate(raw, secret)
            result = _execute(action, install_dir)
            _atomic_json(results / path.name, result)
        except Exception as exc:
            _atomic_json(
                rejected / path.name,
                {
                    "status": "rejected",
                    "finished_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "message": str(exc)[:500],
                },
            )
        finally:
            path.unlink(missing_ok=True)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="ouo-node-agent")
    parser.add_argument("--spool", default="/var/lib/ouo-agent")
    parser.add_argument("--install-dir", default="/opt/messenger/project")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    secret = os.environ.get("OWNER_AGENT_SECRET", "")
    if len(secret) < 32:
        parser.error("OWNER_AGENT_SECRET must contain at least 32 characters")
    spool = Path(args.spool)
    install_dir = Path(args.install_dir)
    if not (install_dir / "docker-compose.yml").is_file():
        parser.error("install directory does not contain docker-compose.yml")
    while True:
        process_once(spool, install_dir, secret)
        if args.once:
            return 0
        time.sleep(max(0.2, args.interval))


if __name__ == "__main__":
    raise SystemExit(main())
