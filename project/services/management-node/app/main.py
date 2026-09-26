"""Headless management API for a locally owned OUO node.

This service intentionally has no web UI and is expected to be bound to
loopback or a private VPN interface by the deployment layer.
"""

import base64
import hashlib
import hmac
import json
import os
import shutil
import tempfile
import time
import uuid
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field, field_validator

from shared.security.keys import load_or_create_signing_key
from shared.security.keys import sign_message, verify_message
from shared.security.canonical import canonical_json
from shared.security.body_limit import RequestBodyLimitMiddleware
from shared.security.metrics import RateLimiter
from shared.security.owner_management_store import OwnerManagementStore


ROOT_KEY_PATH = os.environ.get("NODE_ROOT_KEY_PATH", "/data/node_root_key")
STATE_PATH = os.environ.get(
    "OWNER_MANAGEMENT_STATE_PATH", "/data/owner_management_state.json"
)
STARTED_MONOTONIC = time.monotonic()
RUNTIME_CONFIG_PATH = os.environ.get(
    "OWNER_RUNTIME_CONFIG_PATH", "/data/owner_runtime_config.json"
)
AUDIT_PATH = os.environ.get("OWNER_AUDIT_PATH", "/data/owner_audit.jsonl")
GATEWAY_INTERNAL_URL = os.environ.get("GATEWAY_INTERNAL_URL", "")
GATEWAY_INVITE_SECRET = os.environ.get("GATEWAY_INVITE_SECRET", "")
AGENT_SPOOL_PATH = os.environ.get("OWNER_AGENT_SPOOL_PATH", "/agent")
AGENT_SECRET = os.environ.get("OWNER_AGENT_SECRET", "")
ALLOWED_SERVICES = frozenset(
    {"home-node", "relay-node", "storage-node", "discovery-node", "gateway-node", "management-node"}
)


class RuntimeConfig(BaseModel):
    roles: list[str] = Field(default_factory=lambda: ["home", "management"], min_length=1)
    accept_invites: bool = False
    max_users: int = Field(default=100, ge=1, le=100_000)
    max_storage_gb: int = Field(default=20, ge=1, le=100_000)
    max_connections: int = Field(default=1_000, ge=10, le=1_000_000)
    transit_enabled: bool = False

    @field_validator("roles")
    @classmethod
    def validate_roles(cls, values: list[str]) -> list[str]:
        allowed = {"home", "relay", "storage", "discovery", "gateway", "management"}
        normalized = sorted({value.strip().lower() for value in values})
        if (
            not normalized
            or "management" not in normalized
            or any(value not in allowed for value in normalized)
        ):
            raise ValueError("unsupported node role")
        return normalized


class InviteRequest(BaseModel):
    label: str | None = Field(default=None, max_length=256)
    ttl_seconds: int = Field(default=900, ge=30, le=86400)


class RestoreConfigRequest(BaseModel):
    backup: dict[str, Any]


BACKUP_PROTOCOL = "ouo-owner-config-backup/1"
BACKUP_DOMAIN = b"OUO/OWNER_CONFIG_BACKUP/v1\x00"


def _create_config_backup() -> dict[str, Any]:
    store = get_store()
    backup = {
        "protocol_version": BACKUP_PROTOCOL,
        "node_id": store.node_id,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "config": _read_runtime_config().model_dump(),
    }
    backup["signature"] = sign_message(
        store.node_root_signing_key,
        BACKUP_DOMAIN + canonical_json(backup).encode("utf-8"),
    )
    return backup


def _validate_config_backup(backup: dict[str, Any]) -> RuntimeConfig:
    expected = {"protocol_version", "node_id", "created_at", "config", "signature"}
    if set(backup) != expected or backup.get("protocol_version") != BACKUP_PROTOCOL:
        raise HTTPException(status_code=400, detail="invalid config backup")
    store = get_store()
    if backup.get("node_id") != store.node_id:
        raise HTTPException(status_code=400, detail="config backup belongs to another node")
    unsigned = {key: backup[key] for key in expected - {"signature"}}
    if not verify_message(
        store.node_root_public_key,
        BACKUP_DOMAIN + canonical_json(unsigned).encode("utf-8"),
        str(backup.get("signature", "")),
    ):
        raise HTTPException(status_code=400, detail="invalid config backup signature")
    try:
        return RuntimeConfig.model_validate(backup["config"])
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail="invalid config backup values") from exc


def _default_runtime_config() -> RuntimeConfig:
    raw = os.environ.get("OUO_NODE_ROLES", "home,management")
    roles = [value.strip() for value in raw.split(",") if value.strip()]
    return RuntimeConfig(roles=roles or ["home", "management"])


def _read_runtime_config() -> RuntimeConfig:
    path = Path(RUNTIME_CONFIG_PATH)
    if not path.exists():
        return _default_runtime_config()
    return RuntimeConfig.model_validate_json(path.read_text(encoding="utf-8"))


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


def _audit(action: str, *, serial: str, details: dict[str, Any] | None = None) -> None:
    path = Path(AUDIT_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "action": action,
        "certificate_serial": serial,
        "details": details or {},
    }
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(path, 0o600)


def _enqueue_agent_action(
    action: str, service: str, *, config: dict[str, Any] | None = None
) -> str:
    if not AGENT_SECRET or len(AGENT_SECRET) < 32:
        raise HTTPException(status_code=503, detail="owner agent is not configured")
    if not (
        (action == "service.restart" and service in ALLOWED_SERVICES)
        or (action == "node.update" and service == "node")
        or (action == "config.apply" and service == "node" and config is not None)
    ):
        raise HTTPException(status_code=400, detail="unsupported owner action")
    action_id = str(uuid.uuid4())
    payload = {
        "version": 1,
        "action_id": action_id,
        "action": action,
        "service": service,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if config is not None:
        payload["config"] = config
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    payload["signature"] = hmac.new(
        AGENT_SECRET.encode(), canonical, hashlib.sha256
    ).hexdigest()
    requests_path = Path(AGENT_SPOOL_PATH) / "requests"
    _atomic_json(requests_path / f"{action_id}.json", payload)
    return action_id


def _configured_roles() -> list[str]:
    return _read_runtime_config().roles


def _memory_snapshot() -> dict[str, int | None]:
    total = available = None
    try:
        values: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, value = line.split(":", 1)
            values[key] = int(value.strip().split()[0]) * 1024
        total = values.get("MemTotal")
        available = values.get("MemAvailable")
    except (OSError, ValueError):
        pass
    used = None if total is None or available is None else max(0, total - available)
    return {"total_bytes": total, "used_bytes": used, "available_bytes": available}


def _resource_snapshot() -> dict[str, Any]:
    disk = shutil.disk_usage(Path(STATE_PATH).parent)
    try:
        load = list(os.getloadavg())
    except OSError:
        load = []
    return {
        "cpu_count": os.cpu_count(),
        "load_average": load,
        "memory": _memory_snapshot(),
        "disk": {
            "total_bytes": disk.total,
            "used_bytes": disk.used,
            "free_bytes": disk.free,
        },
    }


class PairRequest(BaseModel):
    pairing_id: str = Field(min_length=36, max_length=36)
    pairing_secret: str = Field(min_length=32, max_length=128)
    device_public_key: str = Field(min_length=40, max_length=64)


@lru_cache
def get_store() -> OwnerManagementStore:
    return OwnerManagementStore(
        STATE_PATH,
        node_root_signing_key=load_or_create_signing_key(ROOT_KEY_PATH),
    )


def _decode_request_header(value: str) -> dict[str, Any]:
    if not value or len(value) > 8192:
        raise HTTPException(status_code=401, detail="owner request signature required")
    try:
        padding = "=" * (-len(value) % 4)
        raw = base64.urlsafe_b64decode((value + padding).encode("ascii"))
        parsed = json.loads(raw)
    except (UnicodeEncodeError, ValueError, TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=401, detail="invalid owner request encoding") from exc
    if not isinstance(parsed, dict):
        raise HTTPException(status_code=401, detail="owner request must be an object")
    return parsed


async def _authorize(
    request: Request,
    encoded_request: str,
    *,
    permission: str,
) -> dict[str, Any]:
    body = await request.body()
    signed_request = _decode_request_header(encoded_request)
    result = get_store().authorize_request(
        signed_request,
        permission=permission,
        now=datetime.now(timezone.utc),
        method=request.method,
        path=request.url.path,
        body=body,
    )
    if not result.valid:
        raise HTTPException(status_code=401, detail=result.reason or "owner request rejected")
    return signed_request


app = FastAPI(
    title="OUO Node Owner Management",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.add_middleware(
    RequestBodyLimitMiddleware,
    path_prefixes=("/owner",),
    max_body_bytes=64 * 1024,
    require_federation_headers=False,
)
_pairing_limiter = RateLimiter(
    rate=0.2,
    capacity=10,
    max_buckets=1024,
    idle_ttl_seconds=600,
)


@app.on_event("startup")
def validate_management_runtime() -> None:
    root = Path(ROOT_KEY_PATH)
    state = Path(STATE_PATH)
    if root.resolve() == state.resolve():
        raise RuntimeError("root key and management state paths must differ")
    get_store()
    _read_runtime_config()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "owner-management",
        "node_id": get_store().node_id,
        "web_panel": False,
    }


@app.post("/owner/v1/pair", status_code=201)
def pair_device(body: PairRequest, request: Request):
    client_host = request.client.host if request.client else "unknown"
    if not _pairing_limiter.allow(client_host):
        raise HTTPException(status_code=429, detail="pairing rate limit exceeded")
    try:
        certificate = get_store().consume_pairing(
            pairing_id=body.pairing_id,
            pairing_secret=body.pairing_secret,
            device_public_key=body.device_public_key,
            now=datetime.now(timezone.utc),
        )
    except ValueError as exc:
        # Do not distinguish unknown IDs from bad secrets over the network.
        raise HTTPException(status_code=401, detail="pairing capability rejected") from exc
    return {"certificate": certificate}


@app.get("/owner/v1/status")
async def owner_status(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="health.read")
    store = get_store()
    return {
        "status": "ok",
        "node_id": store.node_id,
        "service": "owner-management",
        "web_panel": False,
        "version": os.environ.get("OUO_NODE_VERSION", "development"),
        "roles": _configured_roles(),
        "uptime_seconds": int(time.monotonic() - STARTED_MONOTONIC),
        "resources": _resource_snapshot(),
    }


@app.get("/owner/v1/diagnostics")
async def owner_diagnostics(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="diagnostics.read")
    state_parent = Path(STATE_PATH).parent
    checks = [
        {
            "id": "state_storage",
            "status": "ok" if state_parent.exists() and os.access(state_parent, os.W_OK) else "error",
            "summary": "Хранилище состояния доступно для записи",
        },
        {
            "id": "node_root_key",
            "status": "ok" if Path(ROOT_KEY_PATH).is_file() else "error",
            "summary": "Корневой ключ ноды создан",
        },
    ]
    disk = shutil.disk_usage(state_parent)
    disk_ratio = disk.free / disk.total if disk.total else 0
    checks.append(
        {
            "id": "disk_space",
            "status": "ok" if disk_ratio >= 0.1 else "warning",
            "summary": "Свободное место на диске",
            "details": {"free_bytes": disk.free, "total_bytes": disk.total},
        }
    )
    return {
        "status": "ok" if all(item["status"] == "ok" for item in checks) else "attention",
        "checked_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "checks": checks,
    }


@app.get("/owner/v1/config")
async def owner_config(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="settings.read")
    return _read_runtime_config().model_dump()


@app.put("/owner/v1/config")
async def update_owner_config(
    body: RuntimeConfig,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    signed = await _authorize(request, x_ouo_owner_request, permission="settings.write")
    previous = _read_runtime_config()
    action_id = _enqueue_agent_action(
        "config.apply", "node", config=body.model_dump()
    )
    _atomic_json(Path(RUNTIME_CONFIG_PATH), body.model_dump())
    _audit(
        "config.updated",
        serial=str(signed.get("certificate_serial", "")),
        details={"before": previous.model_dump(), "after": body.model_dump()},
    )
    return {
        "status": "saved",
        "config": body.model_dump(),
        "restart_required": True,
        "action_id": action_id,
    }


@app.get("/owner/v1/audit")
async def owner_audit(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="audit.read")
    path = Path(AUDIT_PATH)
    if not path.exists():
        return {"events": []}
    lines = path.read_text(encoding="utf-8").splitlines()[-200:]
    events = [json.loads(line) for line in lines if line.strip()]
    return {"events": list(reversed(events))}


@app.get("/owner/v1/config/backup")
async def owner_config_backup(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="settings.read")
    return _create_config_backup()


@app.post("/owner/v1/config/restore")
async def restore_owner_config(
    body: RestoreConfigRequest,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    signed = await _authorize(request, x_ouo_owner_request, permission="settings.write")
    restored = _validate_config_backup(body.backup)
    previous = _read_runtime_config()
    _atomic_json(Path(RUNTIME_CONFIG_PATH), restored.model_dump())
    _audit(
        "config.restored",
        serial=str(signed.get("certificate_serial", "")),
        details={"before": previous.model_dump(), "after": restored.model_dump()},
    )
    return {"status": "restored", "config": restored.model_dump(), "restart_required": True}


@app.post("/owner/v1/invites")
async def create_owner_invite(
    body: InviteRequest,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    signed = await _authorize(request, x_ouo_owner_request, permission="invites.create")
    config = _read_runtime_config()
    if not config.accept_invites:
        raise HTTPException(status_code=409, detail="owner invites are disabled")
    if not GATEWAY_INTERNAL_URL or not GATEWAY_INVITE_SECRET:
        raise HTTPException(status_code=503, detail="gateway invite integration is unavailable")
    async with httpx.AsyncClient(timeout=5, follow_redirects=False) as client:
        response = await client.post(
            f"{GATEWAY_INTERNAL_URL.rstrip('/')}/gateway/invite/create",
            headers={"X-Gateway-Invite-Secret": GATEWAY_INVITE_SECRET},
            json={"label": body.label, "ttl_seconds": body.ttl_seconds},
        )
    if response.status_code < 200 or response.status_code >= 300:
        raise HTTPException(status_code=502, detail="gateway rejected invite creation")
    result = response.json()
    _audit(
        "invite.created",
        serial=str(signed.get("certificate_serial", "")),
        details={"label": body.label, "ttl_seconds": body.ttl_seconds},
    )
    return result


@app.post("/owner/v1/services/{service}/restart", status_code=202)
async def restart_owner_service(
    service: str,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    signed = await _authorize(request, x_ouo_owner_request, permission="service.restart")
    action_id = _enqueue_agent_action("service.restart", service)
    _audit(
        "service.restart.requested",
        serial=str(signed.get("certificate_serial", "")),
        details={"service": service, "action_id": action_id},
    )
    return {"status": "accepted", "action_id": action_id}


@app.post("/owner/v1/updates/apply", status_code=202)
async def apply_owner_update(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    signed = await _authorize(request, x_ouo_owner_request, permission="settings.write")
    action_id = _enqueue_agent_action("node.update", "node")
    _audit(
        "node.update.requested",
        serial=str(signed.get("certificate_serial", "")),
        details={"action_id": action_id},
    )
    return {"status": "accepted", "action_id": action_id}


@app.get("/owner/v1/actions/{action_id}")
async def owner_action_status(
    action_id: str,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="health.read")
    try:
        canonical_id = str(uuid.UUID(action_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="invalid action id") from exc
    result_path = Path(AGENT_SPOOL_PATH) / "results" / f"{canonical_id}.json"
    request_path = Path(AGENT_SPOOL_PATH) / "requests" / f"{canonical_id}.json"
    if result_path.is_file():
        return json.loads(result_path.read_text(encoding="utf-8"))
    if request_path.is_file():
        return {"status": "pending", "action_id": canonical_id}
    raise HTTPException(status_code=404, detail="owner action not found")


@app.get("/owner/v1/devices")
async def owner_devices(
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="devices.read")
    return {"devices": get_store().list_devices(now=datetime.now(timezone.utc))}


@app.post("/owner/v1/devices/{serial}/revoke", status_code=200)
async def revoke_owner_device(
    serial: str,
    request: Request,
    x_ouo_owner_request: str = Header("", alias="X-OUO-Owner-Request"),
):
    await _authorize(request, x_ouo_owner_request, permission="devices.revoke")
    if not get_store().revoke_device(serial):
        raise HTTPException(status_code=404, detail="owner device not found")
    return {"status": "revoked", "serial": serial}
