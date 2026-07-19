"""PreKey bundle helpers (P7) — server-side one-time prekey consumption."""
import copy
import os
from typing import Any, Optional

PREKEY_CONSUMPTION_MODE = os.environ.get("PREKEY_CONSUMPTION_MODE", "legacy").lower()


def count_unused_prekeys(bundle: dict) -> int:
    consumed = set(bundle.get("consumed_prekey_ids") or [])
    return sum(1 for p in bundle.get("prekeys") or [] if p.get("id") not in consumed)


def merge_prekeys(bundle: dict, new_prekeys: list[dict]) -> dict:
    updated = copy.deepcopy(bundle)
    existing_ids = {p["id"] for p in updated.get("prekeys") or []}
    for pk in new_prekeys:
        pk_id = pk.get("id")
        if pk_id is None or pk_id in existing_ids:
            continue
        updated.setdefault("prekeys", []).append(pk)
        existing_ids.add(pk_id)
    return updated


def consume_one_prekey(bundle: dict) -> tuple[dict, dict]:
    """
    Mark one OTP prekey consumed. Returns (updated_bundle, client_bundle).
    Raises ValueError when no prekeys remain.
    """
    updated = copy.deepcopy(bundle)
    prekeys = updated.get("prekeys") or []
    consumed = set(updated.get("consumed_prekey_ids") or [])
    available = [p for p in prekeys if p.get("id") not in consumed]
    if not available:
        raise ValueError("no one-time prekeys available")

    selected = available[0]
    consumed.add(selected["id"])
    updated["consumed_prekey_ids"] = sorted(consumed)

    client_bundle = {
        "identity_key": updated["identity_key"],
        "registration_id": updated["registration_id"],
        "signed_prekey": updated["signed_prekey"],
        "prekeys": [selected],
    }
    return updated, client_bundle


def resolve_prekey_mode(api_version: Optional[int] = None) -> str:
    """v=1 → strict; v=0 → legacy; absent → PREKEY_CONSUMPTION_MODE env."""
    if api_version == 1:
        return "strict"
    if api_version == 0:
        return "legacy"
    return PREKEY_CONSUMPTION_MODE


def build_prekey_bundle_response(
    device_id: str,
    bundle: dict,
    *,
    api_version: Optional[int] = None,
) -> dict[str, Any]:
    mode = resolve_prekey_mode(api_version)
    if mode == "legacy":
        result: dict[str, Any] = {"device_id": device_id, "bundle": bundle}
        if api_version == 0:
            result["api_version"] = 0
            result["prekey_mode"] = "legacy"
        return result

    updated, client_bundle = consume_one_prekey(bundle)
    result = {
        "device_id": device_id,
        "bundle": client_bundle,
        "_updated_bundle": updated,
        "api_version": api_version if api_version is not None else 1,
        "prekey_mode": "strict",
        "unused_prekeys": count_unused_prekeys(updated),
    }
    return result
