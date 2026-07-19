"""
Read/write project .env and config/storage.json for the admin GUI.
Terminal users can edit the same files directly — this module is the only
writer the GUI uses.
"""
import json
import os
from pathlib import Path
from typing import Any, Dict

from app.schemas import FullAdminConfig, NodeEnvConfig, StorageConfigFile
from app.secrets import is_secret_placeholder

PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", "/project"))
ENV_PATH = Path(os.environ.get("ENV_FILE", PROJECT_ROOT / ".env"))
STORAGE_CONFIG_PATH = Path(os.environ.get("STORAGE_CONFIG", PROJECT_ROOT / "config" / "storage.json"))

ENV_KEY_MAP = {
    "discovery_node_url": "DISCOVERY_NODE_URL",
    "cluster_id": "CLUSTER_ID",
    "node_resource_policy": "NODE_RESOURCE_POLICY",
    "home_node_public_url": "HOME_NODE_PUBLIC_URL",
    "storage_node_url": "STORAGE_NODE_URL",
    "media_node_public_url": "MEDIA_NODE_PUBLIC_URL",
    "relay_node_public_url": "RELAY_NODE_PUBLIC_URL",
    "jwt_secret": "JWT_SECRET",
    "owner_resource_percent": "OWNER_RESOURCE_PERCENT",
    "participate_relay": "NODE_PARTICIPATE_RELAY",
    "participate_storage": "NODE_PARTICIPATE_STORAGE",
    "participate_witness": "NODE_PARTICIPATE_WITNESS",
    "participate_media_cache": "NODE_PARTICIPATE_MEDIA_CACHE",
    "participate_nat_assist": "NODE_PARTICIPATE_NAT_ASSIST",
}


def _parse_env(text: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def _env_bool(data: Dict[str, str], key: str, default: bool) -> bool:
    raw = data.get(key)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _render_env(existing: Dict[str, str], node: NodeEnvConfig) -> str:
    merged = dict(existing)
    for field, env_key in ENV_KEY_MAP.items():
        val = getattr(node, field)
        if val is None:
            continue
        if isinstance(val, bool):
            merged[env_key] = "true" if val else "false"
        else:
            merged[env_key] = str(val)
    if node.jwt_secret is not None and not is_secret_placeholder(node.jwt_secret):
        merged["JWT_SECRET"] = node.jwt_secret
    if node.lan_ip and node.lan_ip not in ("127.0.0.1", "localhost"):
        ip = node.lan_ip
        merged.setdefault("DISCOVERY_NODE_URL", f"http://{ip}:8003")
        merged.setdefault("HOME_NODE_PUBLIC_URL", f"http://{ip}:8001")
        merged.setdefault("STORAGE_NODE_URL", f"http://{ip}:8002")
        merged.setdefault("MEDIA_NODE_PUBLIC_URL", f"http://{ip}:8004")
        merged.setdefault("RELAY_NODE_PUBLIC_URL", f"http://{ip}:8005")

    known = {
        "DISCOVERY_NODE_URL", "CLUSTER_ID", "NODE_RESOURCE_POLICY",
        "OWNER_RESOURCE_PERCENT",
        "NODE_PARTICIPATE_RELAY", "NODE_PARTICIPATE_STORAGE",
        "NODE_PARTICIPATE_WITNESS", "NODE_PARTICIPATE_MEDIA_CACHE",
        "NODE_PARTICIPATE_NAT_ASSIST",
        "HOME_NODE_ID", "HOME_NODE_PUBLIC_URL", "STORAGE_NODE_URL", "JWT_SECRET",
        "STORAGE_NODE_ID", "STORAGE_NODE_PUBLIC_URL",
        "MEDIA_NODE_ID", "MEDIA_NODE_PUBLIC_URL",
        "RELAY_NODE_ID", "RELAY_NODE_PUBLIC_URL",
        "TURN_NODE_ID", "TURN_NODE_PUBLIC_URL", "TURN_SHARED_SECRET",
        "ADMIN_PORT", "STORAGE_CONFIG",
    }
    lines = [
        "# Written by Admin Setup GUI — edit manually anytime; unknown keys are kept on save.",
        f"DISCOVERY_NODE_URL={merged.get('DISCOVERY_NODE_URL', node.discovery_node_url)}",
        f"CLUSTER_ID={merged.get('CLUSTER_ID', node.cluster_id)}",
        f"NODE_RESOURCE_POLICY={merged.get('NODE_RESOURCE_POLICY', node.node_resource_policy)}",
        f"OWNER_RESOURCE_PERCENT={merged.get('OWNER_RESOURCE_PERCENT', str(node.owner_resource_percent))}",
        "",
        "# Участие ноды в общей сети (true/false)",
        f"NODE_PARTICIPATE_RELAY={merged.get('NODE_PARTICIPATE_RELAY', 'true' if node.participate_relay else 'false')}",
        f"NODE_PARTICIPATE_STORAGE={merged.get('NODE_PARTICIPATE_STORAGE', 'true' if node.participate_storage else 'false')}",
        f"NODE_PARTICIPATE_WITNESS={merged.get('NODE_PARTICIPATE_WITNESS', 'true' if node.participate_witness else 'false')}",
        f"NODE_PARTICIPATE_MEDIA_CACHE={merged.get('NODE_PARTICIPATE_MEDIA_CACHE', 'true' if node.participate_media_cache else 'false')}",
        f"NODE_PARTICIPATE_NAT_ASSIST={merged.get('NODE_PARTICIPATE_NAT_ASSIST', 'true' if node.participate_nat_assist else 'false')}",
        "",
        f"HOME_NODE_ID={merged.get('HOME_NODE_ID', 'home-local')}",
        f"HOME_NODE_PUBLIC_URL={merged.get('HOME_NODE_PUBLIC_URL', node.home_node_public_url)}",
        f"STORAGE_NODE_URL={merged.get('STORAGE_NODE_URL', node.storage_node_url)}",
        f"JWT_SECRET={merged.get('JWT_SECRET', 'dev-secret-change-me-in-production')}",
        "",
        f"STORAGE_NODE_ID={merged.get('STORAGE_NODE_ID', 'storage-local')}",
        f"STORAGE_NODE_PUBLIC_URL={merged.get('STORAGE_NODE_PUBLIC_URL', merged.get('STORAGE_NODE_URL', node.storage_node_url))}",
        "",
        f"MEDIA_NODE_ID={merged.get('MEDIA_NODE_ID', 'media-local')}",
        f"MEDIA_NODE_PUBLIC_URL={merged.get('MEDIA_NODE_PUBLIC_URL', node.media_node_public_url)}",
        "",
        f"RELAY_NODE_ID={merged.get('RELAY_NODE_ID', 'relay-local')}",
        f"RELAY_NODE_PUBLIC_URL={merged.get('RELAY_NODE_PUBLIC_URL', node.relay_node_public_url)}",
        "",
        f"TURN_NODE_ID={merged.get('TURN_NODE_ID', 'turn-local')}",
        f"TURN_NODE_PUBLIC_URL={merged.get('TURN_NODE_PUBLIC_URL', 'http://localhost:8006')}",
        f"TURN_SHARED_SECRET={merged.get('TURN_SHARED_SECRET', 'dev-local-turn-secret')}",
        "",
        f"ADMIN_PORT={merged.get('ADMIN_PORT', '9201')}",
        f"STORAGE_CONFIG={merged.get('STORAGE_CONFIG', str(STORAGE_CONFIG_PATH))}",
    ]
    for key in sorted(merged):
        if key not in known:
            lines.append(f"{key}={merged[key]}")
    return "\n".join(lines) + "\n"



def parse_env_file() -> Dict[str, str]:
    if not ENV_PATH.exists():
        return {}
    return _parse_env(ENV_PATH.read_text(encoding="utf-8"))


def read_env_config() -> NodeEnvConfig:
    if not ENV_PATH.exists():
        return NodeEnvConfig()
    data = parse_env_file()
    try:
        owner_pct = int(data.get("OWNER_RESOURCE_PERCENT", "40"))
    except ValueError:
        owner_pct = 40
    owner_pct = max(0, min(100, owner_pct))
    return NodeEnvConfig(
        discovery_node_url=data.get("DISCOVERY_NODE_URL", "http://localhost:8003"),
        cluster_id=data.get("CLUSTER_ID", "default"),
        node_resource_policy=data.get("NODE_RESOURCE_POLICY", "federated"),  # type: ignore[arg-type]
        home_node_public_url=data.get("HOME_NODE_PUBLIC_URL", "http://localhost:8001"),
        storage_node_url=data.get("STORAGE_NODE_URL", "http://localhost:8002"),
        media_node_public_url=data.get("MEDIA_NODE_PUBLIC_URL", "http://localhost:8004"),
        relay_node_public_url=data.get("RELAY_NODE_PUBLIC_URL", "http://localhost:8005"),
        jwt_secret=data.get("JWT_SECRET", "dev-secret-change-me-in-production"),
        owner_resource_percent=owner_pct,
        participate_relay=_env_bool(data, "NODE_PARTICIPATE_RELAY", True),
        participate_storage=_env_bool(data, "NODE_PARTICIPATE_STORAGE", True),
        participate_witness=_env_bool(data, "NODE_PARTICIPATE_WITNESS", False),
        participate_media_cache=_env_bool(data, "NODE_PARTICIPATE_MEDIA_CACHE", False),
        participate_nat_assist=_env_bool(data, "NODE_PARTICIPATE_NAT_ASSIST", False),
    )


def write_env_config(node: NodeEnvConfig) -> None:
    ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
    existing = _parse_env(ENV_PATH.read_text(encoding="utf-8")) if ENV_PATH.exists() else {}
    ENV_PATH.write_text(_render_env(existing, node), encoding="utf-8")


def read_storage_config() -> StorageConfigFile:
    if not STORAGE_CONFIG_PATH.exists():
        return StorageConfigFile()
    raw = json.loads(STORAGE_CONFIG_PATH.read_text(encoding="utf-8"))
    return StorageConfigFile.model_validate(raw)


def write_storage_config(storage: StorageConfigFile) -> None:
    STORAGE_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    STORAGE_CONFIG_PATH.write_text(
        storage.model_dump_json(indent=2) + "\n",
        encoding="utf-8",
    )


def read_full_config() -> FullAdminConfig:
    return FullAdminConfig(node=read_env_config(), storage=read_storage_config())


def write_full_config(config: FullAdminConfig) -> None:
    write_env_config(config.node)
    write_storage_config(config.storage)
