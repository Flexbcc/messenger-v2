"""
Map profile_settings (storage_ownership) → media-node personal_cloud user profile.

Frontend catalog keys (ouo-settings-spec) drive where encrypted blobs live:
- storage.media_location: sender_device | personal_node_s3 | selected_s3 | recipient_cache
- storage.message_location: device_only | personal_node | selected_node | replicated_nodes
- optional personal_pc pairing fields when storage-app is linked
"""
from __future__ import annotations

from typing import Any, Optional


def _values(profile_settings: dict | None) -> dict[str, Any]:
    if not profile_settings:
        return {}
    return profile_settings.get("values") or {}


def build_media_user_profile(
    user_id: str,
    profile_settings: dict | None,
    *,
    default_relay_url: str = "",
) -> Optional[dict]:
    """
    Returns a personal_cloud.users[user_id] fragment for media-node factory,
    or None when server-side personal storage is not requested.
    """
    values = _values(profile_settings)
    media_loc = values.get("storage.media_location", "personal_node_s3")
    message_loc = values.get("storage.message_location", "device_only")

    # Explicit personal_pc pairing (storage-app) — convention keys until catalog adds them.
    peer_pubkey = values.get("storage.personal_pc_peer_pubkey") or values.get("storage.peer_pubkey")
    lan_hint = values.get("storage.personal_pc_lan_hint") or values.get("storage.lan_hint")
    relay_url = values.get("storage.personal_pc_relay_url") or default_relay_url
    storage_node_id = values.get("storage.personal_pc_storage_node_id")
    has_relay = bool(relay_url and storage_node_id)
    if peer_pubkey and (lan_hint or has_relay):
        quota_raw = values.get("storage.personal_pc_quota_bytes", 0)
        try:
            quota_bytes = int(quota_raw)
        except (TypeError, ValueError):
            quota_bytes = 0
        return {
            "backend": "personal_pc",
            "personal_pc": {
                "peer_pubkey": str(peer_pubkey),
                "relay_url": str(relay_url or ""),
                "lan_hint": str(lan_hint or ""),
                "storage_node_id": str(storage_node_id or ""),
                "quota_bytes": quota_bytes,
            },
        }

    if media_loc == "selected_s3":
        endpoint = (values.get("storage.s3_endpoint") or "").strip()
        bucket = (values.get("storage.s3_bucket") or "").strip()
        if endpoint and bucket:
            return {
                "backend": "s3",
                "s3": {
                    "enabled": True,
                    "endpoint_url": endpoint,
                    "bucket": bucket,
                    "access_key": values.get("storage.s3_access_key") or "",
                    "secret_key": values.get("storage.s3_secret_key") or "",
                    "region": values.get("storage.s3_region") or "us-east-1",
                    "prefix": values.get("storage.s3_prefix") or f"users/{user_id}/",
                },
            }

    if media_loc == "personal_node_s3":
        # Operator-managed bucket on the user's home cluster — fall back to node primary.
        return {"backend": "local"}

    if media_loc == "recipient_cache":
        return None

    if media_loc == "sender_device":
        return None

    # Message-only personal node selection (no dedicated media backend yet).
    if message_loc in ("personal_node", "selected_node", "replicated_nodes"):
        return {"backend": "local"}

    return None


def build_storage_policy_summary(profile_settings: dict | None) -> dict:
    """Human-readable + machine policy for internal APIs."""
    values = _values(profile_settings)
    profile = build_media_user_profile("", profile_settings or {})
    return {
        "message_location": values.get("storage.message_location", "device_only"),
        "media_location": values.get("storage.media_location", "personal_node_s3"),
        "replication_factor": values.get("storage.replication_factor"),
        "message_nodes": (profile_settings or {}).get("lists", {}).get("storage.message_nodes", []),
        "media_profile": profile,
    }
