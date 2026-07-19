"""Publish user profile to Discovery registry."""
from __future__ import annotations

from app.federation import publish_user_to_discovery
from app.models import Device, User
from app.profile_helpers import username_search_enabled


async def republish_user_to_discovery(user: User, device: Device) -> None:
    await publish_user_to_discovery(
        user_id=user.id,
        display_name=user.display_name,
        auth_public_key=device.auth_public_key,
        login=user.login,
        username_search_enabled=username_search_enabled(user.profile_settings),
    )
