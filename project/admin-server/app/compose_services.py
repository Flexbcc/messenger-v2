"""Docker Compose service control for Operator Admin."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", "/project"))
COMPOSE_FILE = Path(os.environ.get("COMPOSE_FILE", PROJECT_ROOT / "docker-compose.yml"))
COMPOSE_PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "").strip() or PROJECT_ROOT.name

ALLOWED_SERVICES = frozenset(
    {
        "home-node",
        "storage-node",
        "media-node",
        "relay-node",
        "discovery-node",
        "turn-node",
        "gateway-node",
    }
)

SERVICE_META: dict[str, dict[str, Any]] = {
    "home-node": {"label": "Home Node", "role": "home", "port": 8001, "optional": False},
    "storage-node": {"label": "Storage", "role": "storage", "port": 8002, "optional": False},
    "media-node": {"label": "Media", "role": "media", "port": 8004, "optional": True},
    "relay-node": {"label": "Relay", "role": "relay", "port": 8005, "optional": True},
    "discovery-node": {"label": "Discovery", "role": "discovery", "port": 8003, "optional": True},
    "turn-node": {"label": "TURN", "role": "turn", "port": 8006, "optional": True},
    "gateway-node": {"label": "Gateway", "role": "gateway", "port": 8007, "optional": True},
}


def _docker_available() -> bool:
    sock = Path("/var/run/docker.sock")
    # Do not call `docker info` here. On Docker Desktop it can be noticeably
    # slower than the actual status query and made the setup page look empty.
    return sock.exists() and shutil.which("docker") is not None


def _compose_cmd(*args: str) -> list[str]:
    cmd = ["docker", "compose", "-f", str(COMPOSE_FILE), "-p", COMPOSE_PROJECT]
    cmd.extend(args)
    return cmd


def _run(cmd: list[str], timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(PROJECT_ROOT),
        check=False,
    )


def _parse_compose_services() -> list[str]:
    if not COMPOSE_FILE.exists():
        return []
    # The admin panel manages an explicit allow-list, so rendering status does
    # not need a second Docker/Compose subprocess. Actions still validate the
    # selected service before changing container state.
    compose_text = COMPOSE_FILE.read_text(encoding="utf-8", errors="ignore")
    return [name for name in SERVICE_META if f"  {name}:" in compose_text]


def _docker_ps_by_service() -> dict[str, dict[str, str]]:
    proc = _run(
        [
            "docker",
            "ps",
            "-a",
            "--filter",
            f"label=com.docker.compose.project={COMPOSE_PROJECT}",
            "--format",
            "{{json .}}",
        ],
        timeout=30,
    )
    rows: dict[str, dict[str, str]] = {}
    if proc.returncode != 0:
        return rows
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        labels = item.get("Labels") or ""
        if isinstance(labels, str):
            service = ""
            for part in labels.split(","):
                if part.startswith("com.docker.compose.service="):
                    service = part.split("=", 1)[1]
                    break
        else:
            service = (labels or {}).get("com.docker.compose.service", "")
        if service:
            rows[service] = {
                "State": item.get("State") or "",
                "Status": item.get("Status") or "",
                "Name": item.get("Names") or "",
            }
    return rows


def services_status() -> dict[str, Any]:
    docker_ok = _docker_available()
    defined = [s for s in _parse_compose_services() if s in ALLOWED_SERVICES]
    ps = _docker_ps_by_service() if docker_ok else {}
    services: list[dict[str, Any]] = []
    for name in defined:
        meta = SERVICE_META.get(name, {"label": name, "role": name, "port": None, "optional": True})
        row = ps.get(name, {})
        state = (row.get("State") or row.get("Status") or "not_created").lower()
        running = state == "running" or state.startswith("up")
        services.append(
            {
                "name": name,
                "label": meta["label"],
                "role": meta["role"],
                "port": meta.get("port"),
                "optional": meta.get("optional", True),
                "state": state,
                "running": running,
                "container": row.get("Name") or "",
            }
        )
    return {
        "docker_available": docker_ok,
        "compose_file": str(COMPOSE_FILE),
        "compose_project": COMPOSE_PROJECT,
        "services": services,
        "hint": None
        if docker_ok
        else "Docker socket недоступен — подключите /var/run/docker.sock к контейнеру admin.",
    }


def _validate_service(name: str) -> None:
    if name not in ALLOWED_SERVICES:
        raise ValueError(f"Unknown service: {name}")
    defined = _parse_compose_services()
    if name not in defined:
        raise ValueError(f"Service {name} is not in {COMPOSE_FILE.name}")


def service_action(name: str, action: str) -> dict[str, Any]:
    if action not in {"start", "stop", "restart"}:
        raise ValueError("Invalid action")
    if not _docker_available():
        raise RuntimeError("Docker недоступен")
    _validate_service(name)

    ps = _docker_ps_by_service().get(name, {})
    container = ps.get("Name", "")

    if action == "start":
        if container:
            proc = _run(["docker", "start", container], timeout=120)
        else:
            proc = _run(_compose_cmd("up", "-d", name), timeout=180)
    elif action == "stop":
        if not container:
            raise RuntimeError(f"Контейнер {name} не создан")
        proc = _run(["docker", "stop", container], timeout=120)
    else:
        if container:
            proc = _run(["docker", "restart", container], timeout=120)
        else:
            proc = _run(_compose_cmd("up", "-d", name), timeout=180)

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "docker failed").strip()
        raise RuntimeError(err[:500])
    return {"status": "ok", "service": name, "action": action, **services_status()}


def apply_config_restart(services: list[str] | None = None) -> dict[str, Any]:
    """Recreate services so Compose actually reloads the updated ``.env``.

    A plain container restart preserves the old environment. Setup settings
    are environment-backed, therefore applying them requires replacement
    containers. One Compose invocation also avoids reporting partial success.
    """
    targets = services or ["home-node"]
    for svc in targets:
        _validate_service(svc)
    if not _docker_available():
        raise RuntimeError("Docker недоступен")

    proc = _run(
        _compose_cmd("up", "-d", "--no-deps", "--force-recreate", *targets),
        timeout=300,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "docker compose failed").strip()
        raise RuntimeError(err[:1000])
    return {
        "status": "ok",
        "applied_services": targets,
        "message": "Configuration applied by recreating selected services",
        **services_status(),
    }
