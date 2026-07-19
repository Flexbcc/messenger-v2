"""Fetch per-user storage profile from Home Node (profile_settings → media backend)."""
from __future__ import annotations

import logging
import os
import time
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

HOME_NODE_URL = os.environ.get("HOME_NODE_URL", "").rstrip("/")
PROFILE_CACHE_TTL_SECONDS = int(os.environ.get("HOME_STORAGE_PROFILE_CACHE_SECONDS", "60"))

_cache: dict[str, tuple[float, Optional[dict]]] = {}


def home_storage_profiles_enabled() -> bool:
    return bool(HOME_NODE_URL)


def fetch_user_storage_profile_sync(user_id: str) -> Optional[dict]:
    """
    Returns personal_cloud.users[user_id] fragment or None.
    Uses in-process cache; best-effort on errors.
    """
    if not HOME_NODE_URL or not user_id:
        return None

    now = time.monotonic()
    cached = _cache.get(user_id)
    if cached and now - cached[0] < PROFILE_CACHE_TTL_SECONDS:
        return cached[1]

    url = f"{HOME_NODE_URL}/internal/users/{user_id}/storage-profile"
    try:
        with httpx.Client(timeout=5.0) as client:
            resp = client.get(url)
        if resp.status_code == 404:
            profile = None
        else:
            resp.raise_for_status()
            profile = resp.json().get("profile")
    except httpx.HTTPError as exc:
        logger.warning("Home storage profile fetch failed for %s: %s", user_id, exc)
        return cached[1] if cached else None

    _cache[user_id] = (now, profile)
    return profile


def invalidate_user_storage_profile(user_id: str) -> None:
    _cache.pop(user_id, None)
