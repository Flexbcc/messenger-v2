"""Redact secrets in admin API responses; merge on write when placeholder unchanged."""
import secrets
from typing import Any, Dict, Optional

from app.schemas import FullAdminConfig, NodeEnvConfig, StorageConfigFile

SECRET_PLACEHOLDER = "••••••••••••••••"
_KNOWN_INSECURE_SECRETS = {
    "changeme",
    "change-me",
    "change-me-please",
    "dev-secret-change-me-in-production",
    "dev-local-turn-secret",
}


def generate_service_secret() -> str:
    """Return a high-entropy secret suitable for JWT/HMAC service keys."""
    return secrets.token_urlsafe(48)


def is_insecure_service_secret(value: Optional[str]) -> bool:
    if value is None:
        return True
    candidate = value.strip()
    return (
        len(candidate.encode("utf-8")) < 32
        or candidate.lower() in _KNOWN_INSECURE_SECRETS
        or "change-me" in candidate.lower()
    )


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
        existing = existing_env.get("JWT_SECRET")
        merged.jwt_secret = (
            generate_service_secret()
            if is_insecure_service_secret(existing)
            else existing
        )
    elif is_insecure_service_secret(incoming.jwt_secret):
        raise ValueError("JWT secret must contain at least 32 bytes of entropy")
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
            "jwt_is_dev_default": is_insecure_service_secret(
                env_map.get("JWT_SECRET")
            ),
        },
    }
