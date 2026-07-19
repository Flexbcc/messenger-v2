"""Link a messenger user to storage-app via QR / JSON pairing payload."""

from __future__ import annotations

from copy import deepcopy
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import User
from shared.storage.personal_pc_pairing import PairingPayloadError, pair_from_qr_payload


def _merge_profile_values(existing: dict | None, patch: dict[str, Any]) -> dict:
    base = deepcopy(existing) if existing else {}
    values = dict(base.get("values") or {})
    values.update(patch)
    base["values"] = values
    return base


async def pair_user_with_storage_app(
    db: AsyncSession,
    user_id: str,
    payload_raw: str | dict[str, Any],
) -> dict[str, Any]:
    """
    Pair home-node user ↔ storage-app and persist profile_settings keys
    consumed by ``build_media_user_profile``.
    """
    user = await db.get(User, user_id)
    if not user:
        raise PairingPayloadError(f"user not found: {user_id}")

    try:
        result = pair_from_qr_payload(
            payload_raw,
            signing_key_path=settings.signing_key_path,
            node_id=user_id,
            name=f"home:{settings.node_id}",
            caller_node_id=settings.node_id,
        )
    except PairingPayloadError:
        raise
    except Exception as e:
        raise PairingPayloadError(str(e)) from e

    # storage-app peer_pubkey field stores storage side key (for fingerprint check).
    profile_patch = {
        "storage.personal_pc_peer_pubkey": result["storage_pubkey"],
        "storage.personal_pc_lan_hint": result.get("lan_hint") or "",
        "storage.media_location": "personal_node_s3",
    }
    if result.get("relay_url"):
        profile_patch["storage.personal_pc_relay_url"] = result["relay_url"]
    if result.get("storage_node_id"):
        profile_patch["storage.personal_pc_storage_node_id"] = result["storage_node_id"]

    user.profile_settings = _merge_profile_values(user.profile_settings, profile_patch)
    await db.commit()
    await db.refresh(user)

    return {
        "status": "paired",
        "user_id": user_id,
        "storage_pubkey": result["storage_pubkey"],
        "lan_hint": result.get("lan_hint"),
        "relay_url": result.get("relay_url"),
        "storage_node_id": result.get("storage_node_id"),
        "fingerprint": result.get("fingerprint"),
        "node_peer_pubkey": result["peer_pubkey"],
        "intent": result.get("intent", "node"),
    }
