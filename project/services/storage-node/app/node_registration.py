"""Storage registration through the shared OUO node lifecycle."""

import logging
from typing import Any

from app.config import settings
from shared.security.node_registration import NodeRegistrationClient


_client = NodeRegistrationClient(settings, logger=logging.getLogger(__name__))


def start_node_registration() -> None:
    _client.start()


async def stop_node_registration() -> None:
    await _client.stop()


def node_registration_status() -> dict[str, Any]:
    return _client.status()
