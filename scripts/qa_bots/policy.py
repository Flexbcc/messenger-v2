"""Client-side privacy policy helpers (mirror SettingsRuntime).

Server enforces username search on Discovery; phone/calls/incoming are
evaluated on the device today — bots assert the same matrix and record
gaps when the API still allows what the client would block.
"""
from __future__ import annotations

from typing import Any


def _values(blob: dict[str, Any] | None) -> dict[str, Any]:
    if not blob:
        return {}
    return dict(blob.get("values") or {})


def _lists(blob: dict[str, Any] | None) -> dict[str, list]:
    if not blob:
        return {}
    raw = blob.get("lists") or {}
    out: dict[str, list] = {}
    for k, v in raw.items():
        if isinstance(v, list):
            out[k] = list(v)
        else:
            out[k] = []
    return out


def username_search_allowed(blob: dict[str, Any] | None) -> bool:
    val = _values(blob).get("privacy.username_search")
    if val is None:
        return True
    return bool(val)


def phone_search_allowed(blob: dict[str, Any] | None) -> bool:
    """privacy.phone_search: nobody|contacts|everyone — UI treats non-everyone as blocked for strangers."""
    policy = str(_values(blob).get("privacy.phone_search", "nobody"))
    return policy == "everyone"


def phone_search_policy(blob: dict[str, Any] | None) -> str:
    return str(_values(blob).get("privacy.phone_search", "nobody"))


def _visibility_allows(
    *,
    policy: str,
    allowlist: list[str],
    viewer_user_id: str,
    is_contact: bool,
) -> bool:
    return {
        "nobody": False,
        "contacts": is_contact,
        "selected": viewer_user_id in allowlist,
        "everyone": True,
        "invites": True,
    }.get(policy, is_contact)


def calls_allowed(
    blob: dict[str, Any] | None,
    caller_id: str,
    *,
    is_contact: bool,
) -> bool:
    policy = str(_values(blob).get("privacy.calls_from", "contacts"))
    allowlist = [str(x) for x in _lists(blob).get("privacy.calls_allowlist", [])]
    return _visibility_allows(
        policy=policy,
        allowlist=allowlist,
        viewer_user_id=caller_id,
        is_contact=is_contact,
    )


def incoming_messages_allowed(
    blob: dict[str, Any] | None,
    sender_id: str,
    *,
    is_contact: bool,
) -> bool:
    policy = str(_values(blob).get("privacy.incoming_messages", "invites"))
    if policy == "nobody":
        return False
    if policy == "contacts":
        return is_contact
    # invites / everyone / unknown
    return True


def group_invites_allowed(
    blob: dict[str, Any] | None,
    actor_id: str,
    *,
    is_contact: bool,
) -> bool:
    policy = str(_values(blob).get("privacy.group_invites", "contacts"))
    allowlist = [str(x) for x in _lists(blob).get("privacy.group_invites_list", [])]
    # catalog may not have list; treat selected like contacts allowlist if present
    if policy == "selected":
        return actor_id in allowlist
    return _visibility_allows(
        policy=policy,
        allowlist=allowlist,
        viewer_user_id=actor_id,
        is_contact=is_contact,
    )


def is_blocked(blob: dict[str, Any] | None, user_id: str) -> bool:
    blocked = [str(x) for x in _lists(blob).get("contacts.blocked_list", [])]
    return user_id in blocked
