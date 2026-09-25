"""Discovery registration through the shared signed node lifecycle."""

import logging
from typing import Any

from app.config import (
    DISCOVERY_SELF_REGISTRATION_ENABLED,
    discovery_registration_settings,
)
from shared.security.node_registration import NodeRegistrationClient


_client = NodeRegistrationClient(
    discovery_registration_settings,
    logger=logging.getLogger(__name__),
)


def start_node_registration() -> None:
    if DISCOVERY_SELF_REGISTRATION_ENABLED:
        _client.start()


async def stop_node_registration() -> None:
    if DISCOVERY_SELF_REGISTRATION_ENABLED:
        await _client.stop()


def node_registration_status() -> dict[str, Any]:
    return _client.status()
