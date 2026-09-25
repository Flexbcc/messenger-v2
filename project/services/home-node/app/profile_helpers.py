"""Pure profile helpers (no DB/federation imports — safe for unit tests)."""
from __future__ import annotations

import re

_LOGIN_RE = re.compile(r"^[a-zA-Z0-9_]{3,32}$")


def normalize_login(raw: str | None) -> str | None:
    if raw is None:
        return None
    login = raw.strip().lstrip("@").lower()
    if not login:
        return None
    if not _LOGIN_RE.match(login):
        raise ValueError("login must match ^[a-zA-Z0-9_]{3,32}$")
    return login


def username_search_enabled(profile_settings: dict | None) -> bool:
    if not profile_settings:
        return True
    values = profile_settings.get("values") or {}
    val = values.get("privacy.username_search")
    if val is None:
        return True
    return bool(val)
