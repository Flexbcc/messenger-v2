"""Relay registration plus mesh refresh through the shared node lifecycle."""

import logging
from typing import Any, Mapping

from app.config import settings
from shared.mesh.sync import update_mesh_from_heartbeat_response
from shared.security.node_registration import NodeRegistrationClient


logger = logging.getLogger(__name__)


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
    heartbeat_response_hook=_update_mesh,
)


def start_node_registration() -> None:
    _client.start()


async def stop_node_registration() -> None:
    await _client.stop()


def node_registration_status() -> dict[str, Any]:
    return _client.status()
