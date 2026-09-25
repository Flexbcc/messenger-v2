"""Media registration through the shared OUO node lifecycle."""

import logging

from app.config import settings
from shared.security.node_registration import NodeRegistrationClient


_client = NodeRegistrationClient(settings, logger=logging.getLogger(__name__))


def start_node_registration() -> None:
    _client.start()
