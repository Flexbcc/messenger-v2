"""Owner preferences stored on the Home Node volume (hot-read, no restart)."""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
from typing import Any

from app.config import settings

_PREFS_NAME = "owner_prefs.json"


def prefs_path() -> Path:
    return Path(settings.db_path).expanduser().resolve().parent / _PREFS_NAME


def load_prefs() -> dict[str, Any]:
    path = prefs_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_prefs(patch: dict[str, Any]) -> dict[str, Any]:
    current = load_prefs()
    # Removed legacy pseudo-auth fields. Owner-panel authentication is now
    # provided exclusively by OWNER_PANEL_SECRET and must never be serialized
    # into a UI-readable preferences object.
    current.pop("panel_admin_login", None)
    current.pop("panel_admin_password_hash", None)
    current.update({k: v for k, v in patch.items() if v is not None})
    path = prefs_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(current, indent=2, ensure_ascii=False) + "\n"
    temporary_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary_path = temporary.name
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            try:
                Path(temporary_path).unlink(missing_ok=True)
            except OSError:
                pass
    return current


def effective_participation() -> dict[str, bool]:
    prefs = load_prefs()
    part = prefs.get("participation") if isinstance(prefs.get("participation"), dict) else {}

    def flag(key: str, env_default: bool) -> bool:
        if key in part:
            return bool(part[key])
        return env_default

    relay = flag("relay", settings.participate_relay)
    if settings.resource_policy == "local":
        relay = False
    return {
        "home": True,
        "relay": relay,
        "storage": flag("storage", settings.participate_storage),
        "witness": flag("witness", settings.participate_witness),
        "media_cache": flag("media_cache", settings.participate_media_cache),
        "nat_assist": flag("nat_assist", settings.participate_nat_assist),
    }


def effective_owner_percent() -> int:
    prefs = load_prefs()
    if "owner_resource_percent" in prefs:
        try:
            return max(20, min(100, int(prefs["owner_resource_percent"])))
        except (TypeError, ValueError):
            pass
    return settings.owner_resource_percent
