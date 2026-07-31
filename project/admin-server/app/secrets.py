"""Redact secrets in admin API responses; merge on write when placeholder unchanged."""
from copy import deepcopy
from typing import Any, Dict, Optional, Tuple

from app.schemas import FullAdminConfig, NodeEnvConfig, StorageConfigFile

SECRET_PLACEHOLDER = "••••••••••••••••"


def is_secret_placeholder(value: Optional[str]) -> bool:
    if value is None:
        return True
    v = value.strip()
    if not v:
        return True
    if v == SECRET_PLACEHOLDER:
        return True
    # all bullet chars
    if set(v) <= {"•", "·", "*"}:
        return True
    return False


def discovery_public_url(env: Dict[str, str], fallback: str) -> str:
    for key in ("GATEWAY_DISCOVERY_PUBLIC_URL", "DISCOVERY_PUBLIC_URL", "PUBLIC_DISCOVERY_URL"):
        if env.get(key):
            return env[key]
    public_ip = env.get("PUBLIC_IP")
    port = env.get("DISCOVERY_PORT", "8003")
    if public_ip:
        return f"http://{public_ip}:{port}"
    url = fallback
    if "discovery-node" not in url and "localhost" not in url:
        return url
    return fallback


def _redact_s3(s3: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(s3)
    if out.get("secret_key"):
        out["secret_key"] = SECRET_PLACEHOLDER
    if out.get("access_key") and len(out["access_key"]) > 4:
        out["access_key"] = out["access_key"][:4] + "…"
    return out


def redact_storage_config(storage: StorageConfigFile) -> StorageConfigFile:
    data = storage.model_dump()
    data["media"]["s3"] = _redact_s3(data["media"]["s3"])
    data["backup"]["s3"] = _redact_s3(data["backup"]["s3"])
    return StorageConfigFile.model_validate(data)


def merge_node_secrets(incoming: NodeEnvConfig, existing_env: Dict[str, str]) -> NodeEnvConfig:
    merged = incoming.model_copy()
    if incoming.jwt_secret is None or is_secret_placeholder(incoming.jwt_secret):
        merged.jwt_secret = existing_env.get("JWT_SECRET", "dev-secret-change-me-in-production")
    return merged


def merge_storage_secrets(incoming: StorageConfigFile, existing: StorageConfigFile) -> StorageConfigFile:
    data = incoming.model_dump()
    prev = existing.model_dump()

    for block in ("media", "backup"):
        for field in ("secret_key", "access_key"):
            key_path = data[block]["s3"][field]
            if is_secret_placeholder(key_path):
                data[block]["s3"][field] = prev[block]["s3"][field]

    return StorageConfigFile.model_validate(data)


def read_full_config_for_api(env_map: Dict[str, str], full: FullAdminConfig) -> Dict[str, Any]:
    node = full.node.model_copy()
    node.jwt_secret = None

    return {
        "node": node,
        "storage": redact_storage_config(full.storage),
        "discovery_public_url": discovery_public_url(env_map, full.node.discovery_node_url),
        "secrets": {
            "jwt_secret_set": bool(env_map.get("JWT_SECRET")),
            "jwt_is_dev_default": env_map.get("JWT_SECRET", "") in (
                "",
                "dev-secret-change-me-in-production",
            ),
        },
    }
