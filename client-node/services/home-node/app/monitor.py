"""Monitor API — local metrics + anonymized network for owner panel."""
from pathlib import Path

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_db
from app.models import Device
from app.network_peers import build_anonymous_peers
from app.owner_prefs import (
    effective_owner_percent,
    effective_participation,
    load_prefs,
    save_prefs,
)
from app.runtime_metrics import (
    collect_host_metrics,
    compute_health_score,
    runtime_status_label,
    status_label_ru,
)
from app.ws import manager

router = APIRouter(prefix="/monitor", tags=["monitor"])


class ParticipationPrefs(BaseModel):
    relay: bool | None = None
    storage: bool | None = None
    witness: bool | None = None
    media_cache: bool | None = None
    nat_assist: bool | None = None


class OwnerPrefsUpdate(BaseModel):
    owner_resource_percent: int | None = Field(default=None, ge=20, le=100)
    participation: ParticipationPrefs | None = None


@router.get("/snapshot")
async def monitor_snapshot(db: AsyncSession = Depends(get_db)):
    online_user_ids = list(manager.active.keys())
    ws_count = sum(len(conns) for conns in manager.active.values())

    metrics = collect_host_metrics(str(Path(settings.db_path).parent))
    health = compute_health_score(metrics, ws_count)
    runtime_status = runtime_status_label(health, metrics, ws_count)
    owner_pct = effective_owner_percent()
    network_pct = max(0, 100 - owner_pct)
    participation = effective_participation()

    connections: list[dict] = []
    if online_user_ids:
        result = await db.execute(select(Device).where(Device.user_id.in_(online_user_ids)))
        for device in result.scalars().all():
            user_conns = len(manager.active.get(device.user_id, set()))
            connections.append(
                {
                    "user_id": device.user_id,
                    "device_id": device.id,
                    "device_type": device.device_type,
                    "ws_connections": user_conns,
                    "connected": True,
                }
            )

    known_users = {c["user_id"] for c in connections}
    for uid in online_user_ids:
        if uid not in known_users:
            connections.append(
                {
                    "user_id": uid,
                    "device_id": None,
                    "device_type": "unknown",
                    "ws_connections": len(manager.active.get(uid, set())),
                    "connected": True,
                }
            )

    return {
        "node_id": settings.node_id,
        "node_role": "home",
        "runtime_status": runtime_status,
        "runtime_status_label": status_label_ru(runtime_status),
        "health_score": health,
        "metrics": {
            **metrics,
            "online_users": len(online_user_ids),
            "active_ws_connections": ws_count,
            "sync_queue": 0,
            "relay_jobs": 0,
            "storage_jobs": 0,
        },
        "connections": connections,
        "network": {
            "resource_policy": settings.resource_policy,
            "discovery_configured": bool(settings.discovery_url),
            "software_version": settings.software_version,
            "capabilities": list(settings.capabilities),
            "owner_resource_percent": owner_pct,
            "network_resource_percent": network_pct,
            "participation": participation,
        },
    }


@router.get("/network/peers")
async def anonymous_network_peers(probe: bool = True):
    """Role + status only. No URLs, IPs, or raw node IDs."""
    return await build_anonymous_peers(probe=probe)


@router.get("/prefs")
def get_owner_prefs():
    return {
        "owner_resource_percent": effective_owner_percent(),
        "participation": effective_participation(),
        "stored": load_prefs(),
    }


@router.put("/prefs")
def put_owner_prefs(body: OwnerPrefsUpdate):
    patch: dict = {}
    if body.owner_resource_percent is not None:
        patch["owner_resource_percent"] = body.owner_resource_percent
    if body.participation is not None:
        current = effective_participation()
        incoming = body.participation.model_dump(exclude_none=True)
        merged = {
            "relay": incoming.get("relay", current["relay"]),
            "storage": incoming.get("storage", current["storage"]),
            "witness": incoming.get("witness", current["witness"]),
            "media_cache": incoming.get("media_cache", current["media_cache"]),
            "nat_assist": incoming.get("nat_assist", current["nat_assist"]),
        }
        patch["participation"] = merged
    stored = save_prefs(patch)
    return {
        "status": "saved",
        "owner_resource_percent": effective_owner_percent(),
        "participation": effective_participation(),
        "stored": stored,
    }
