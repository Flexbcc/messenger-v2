"""Generate sample values for catalog settings (L1/L2)."""
from __future__ import annotations

from typing import Any


def sample_value(setting: dict[str, Any], *, variant: str = "primary") -> Any:
    """Return a JSON-serializable value for profile-settings values map.

    Lists go to the `lists` map — use sample_list_value instead.
    """
    typ = setting.get("type") or "text"
    enums = setting.get("enums") or setting.get("options")
    default = setting.get("default")

    if typ == "boolean":
        if variant == "alt":
            return not bool(default) if default is not None else False
        return bool(default) if default is not None else True

    if typ == "single_select":
        opts = list(enums or [])
        if not opts:
            return default if default is not None else "everyone"
        if variant == "alt" and len(opts) > 1:
            return opts[1]
        if default in opts:
            return default
        return opts[0]

    if typ == "multi_select":
        opts = list(enums or [])
        if variant == "empty":
            return []
        if variant == "alt" and len(opts) > 1:
            return opts[:2]
        return [opts[0]] if opts else []

    if typ == "number":
        if isinstance(default, (int, float)):
            return int(default) + (1 if variant == "alt" else 0)
        return 1 if variant == "primary" else 2

    if typ == "text":
        if variant == "alt":
            return "qa_alt_value"
        return default if isinstance(default, str) and default else "qa_value"

    if typ in ("action", "read_only", "secret"):
        return None  # skip in values blob

    if typ == "list":
        return None  # use lists map

    return default


def sample_list_value(setting: dict[str, Any], *, peer_ids: list[str], variant: str = "one") -> list[str]:
    if variant == "empty":
        return []
    if variant == "many" and len(peer_ids) >= 2:
        return list(peer_ids[:2])
    if peer_ids:
        return [peer_ids[0]]
    return ["00000000-0000-0000-0000-000000000001"]


def is_values_key(setting: dict[str, Any]) -> bool:
    typ = setting.get("type") or ""
    if typ in ("action", "read_only", "secret", "list"):
        return False
    return setting.get("storage") == "profile_settings"


def is_lists_key(setting: dict[str, Any]) -> bool:
    return setting.get("storage") == "profile_settings" and setting.get("type") == "list"
