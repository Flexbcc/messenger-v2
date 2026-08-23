"""Discovery Node Identity, separate from the directory-record signing key."""

from functools import lru_cache

from app.config import (
    DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH,
    DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
    DISCOVERY_NODE_ROOT_KEY_PATH,
)
from shared.security.node_identity_credentials import node_identity_registration_fields


@lru_cache
def discovery_node_identity() -> dict:
    return node_identity_registration_fields(
        root_key_path=DISCOVERY_NODE_ROOT_KEY_PATH,
        operational_key_path=DISCOVERY_NODE_OPERATIONAL_KEY_PATH,
        certificate_path=DISCOVERY_NODE_OPERATIONAL_CERTIFICATE_PATH,
    )
