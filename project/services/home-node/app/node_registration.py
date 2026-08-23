"""Home registration with local telemetry and mesh refresh hooks."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

from sqlalchemy import func, select

from app.config import settings
from app.runtime_metrics import collect_host_metrics
from app.ws import manager as ws_manager
from shared.mesh.sync import update_mesh_from_heartbeat_response
from shared.security.node_registration import NodeRegistrationClient


logger = logging.getLogger(__name__)


async def _counters_24h() -> dict[str, int]:
    """Return bounded aggregate counters; never include message metadata."""
    try:
        from app.db import async_session
        from app.models import Message

        since = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
        async with async_session() as database:
            recent = await database.execute(
                select(func.count()).select_from(Message).where(Message.created_at >= since)
            )
            total = await database.execute(select(func.count()).select_from(Message))
        return {
            "messages_24h": int(recent.scalar() or 0),
            "messages_total": int(total.scalar() or 0),
            "calls_24h": 0,
        }
    except Exception as exc:
        logger.debug("Local counters unavailable: %s", exc)
        return {}


async def _heartbeat_telemetry() -> dict[str, Any]:
    payload: dict[str, Any] = {}
    try:
        payload.update(collect_host_metrics())
    except Exception as exc:
        logger.debug("Host metrics unavailable: %s", exc)
    try:
        payload["ws_connections"] = ws_manager.connection_count()
    except Exception as exc:
        logger.debug("WebSocket metrics unavailable: %s", exc)
    payload.update(await _counters_24h())
    return payload


def _update_mesh(payload: Mapping[str, Any]) -> None:
    try:
        update_mesh_from_heartbeat_response(
            dict(payload),
            self_node_id=settings.node_id,
            cluster_id=settings.cluster_id,
        )
    except Exception as exc:
        logger.debug("Mesh update from heartbeat failed: %s", exc)


_client = NodeRegistrationClient(
    settings,
    logger=logger,
    heartbeat_payload_factory=_heartbeat_telemetry,
    heartbeat_response_hook=_update_mesh,
)


def start_node_registration() -> None:
    _client.start()


async def stop_node_registration() -> None:
    await _client.stop()


def node_registration_status() -> dict[str, Any]:
    return _client.status()
