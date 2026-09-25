"""
Read/write project .env and config/storage.json for the admin GUI.
Terminal users can edit the same files directly — this module is the only
writer the GUI uses.
"""
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Dict

from app.schemas import FullAdminConfig, NodeEnvConfig, StorageConfigFile
from app.secrets import (
    generate_service_secret,
    is_insecure_service_secret,
    is_secret_placeholder,
)

PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", "/project"))
ENV_PATH = Path(os.environ.get("ENV_FILE", PROJECT_ROOT / ".env"))
STORAGE_CONFIG_PATH = Path(os.environ.get("STORAGE_CONFIG", PROJECT_ROOT / "config" / "storage.json"))

ENV_KEY_MAP = {
    "discovery_node_url": "DISCOVERY_NODE_URL",
    "discovery_public_urls": "GATEWAY_DISCOVERY_PUBLIC_URLS",
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
    "relay_transport_mode": "RELAY_TRANSPORT_MODE",
    "relay_max_persistent_peers": "RELAY_MAX_PERSISTENT_PEERS",
    "peer_guard_count": "PEER_GUARD_COUNT",
    "peer_rotating_count": "PEER_ROTATING_COUNT",
    "peer_reserve_count": "PEER_RESERVE_COUNT",
    "relay_link_idle_seconds": "RELAY_LINK_IDLE_SECONDS",
    "relay_ws_max_connections": "RELAY_WS_MAX_CONNECTIONS",
    "relay_ws_max_connections_per_peer": "RELAY_WS_MAX_CONNECTIONS_PER_PEER",
    "direct_max_connections": "HOME_DIRECT_MAX_CONNECTIONS",
    "direct_max_keepalive_connections": "HOME_DIRECT_MAX_KEEPALIVE_CONNECTIONS",
    "direct_keepalive_expiry_seconds": "HOME_DIRECT_KEEPALIVE_EXPIRY_SECONDS",
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
    if is_insecure_service_secret(merged.get("JWT_SECRET")):
        merged["JWT_SECRET"] = generate_service_secret()
    if is_insecure_service_secret(merged.get("TURN_SHARED_SECRET")):
        merged["TURN_SHARED_SECRET"] = generate_service_secret()
    sources = ",".join(
        dict.fromkeys(
            value.strip().rstrip("/")
            for value in node.discovery_quorum_urls.split(",")
            if value.strip()
        )
    )
    merged["ROUTE_DISCOVERY_URLS"] = sources
    merged["PEER_DISCOVERY_URLS"] = sources
    merged["FEDERATION_DISCOVERY_URLS"] = sources
    merged["MIX_DISCOVERY_URLS"] = sources
    merged["NODE_REGISTRATION_DISCOVERY_URLS"] = sources
    merged["GATEWAY_DISCOVERY_URLS"] = sources or node.discovery_node_url
    public_sources = ",".join(
        dict.fromkeys(
            value.strip().rstrip("/")
            for value in node.discovery_public_urls.split(",")
            if value.strip()
        )
    )
    merged["GATEWAY_DISCOVERY_PUBLIC_URLS"] = (
        public_sources or merged.get("GATEWAY_DISCOVERY_PUBLIC_URL", node.discovery_node_url)
    )
    merged["ROUTE_MINIMUM_DISCOVERY_SOURCES"] = str(node.discovery_minimum_sources)
    merged["PEER_MINIMUM_DISCOVERY_SOURCES"] = str(node.discovery_minimum_sources)
    merged["FEDERATION_MINIMUM_DISCOVERY_SOURCES"] = str(node.discovery_minimum_sources)
    merged["MIX_MINIMUM_DISCOVERY_SOURCES"] = str(node.discovery_minimum_sources)
    if node.lan_ip and node.lan_ip not in ("127.0.0.1", "localhost"):
        ip = node.lan_ip
        merged.setdefault("DISCOVERY_NODE_URL", f"http://{ip}:8003")
        merged.setdefault("HOME_NODE_PUBLIC_URL", f"http://{ip}:8001")
        merged.setdefault("STORAGE_NODE_URL", f"http://{ip}:8002")
        merged.setdefault("MEDIA_NODE_PUBLIC_URL", f"http://{ip}:8004")
        merged.setdefault("RELAY_NODE_PUBLIC_URL", f"http://{ip}:8005")

    known = {
        "DISCOVERY_NODE_URL", "CLUSTER_ID", "NODE_RESOURCE_POLICY",
        "ROUTE_DISCOVERY_URLS", "PEER_DISCOVERY_URLS",
        "FEDERATION_DISCOVERY_URLS", "MIX_DISCOVERY_URLS",
        "NODE_REGISTRATION_DISCOVERY_URLS",
        "GATEWAY_DISCOVERY_URLS", "GATEWAY_DISCOVERY_PUBLIC_URLS",
        "ROUTE_MINIMUM_DISCOVERY_SOURCES", "FEDERATION_MINIMUM_DISCOVERY_SOURCES",
        "MIX_MINIMUM_DISCOVERY_SOURCES", "PEER_MINIMUM_DISCOVERY_SOURCES",
        "OWNER_RESOURCE_PERCENT",
        "NODE_PARTICIPATE_RELAY", "NODE_PARTICIPATE_STORAGE",
        "NODE_PARTICIPATE_WITNESS", "NODE_PARTICIPATE_MEDIA_CACHE",
        "NODE_PARTICIPATE_NAT_ASSIST",
        "RELAY_TRANSPORT_MODE", "RELAY_MAX_PERSISTENT_PEERS",
        "PEER_GUARD_COUNT", "PEER_ROTATING_COUNT", "PEER_RESERVE_COUNT",
        "RELAY_LINK_IDLE_SECONDS", "RELAY_WS_MAX_CONNECTIONS",
        "RELAY_WS_MAX_CONNECTIONS_PER_PEER",
        "HOME_DIRECT_MAX_CONNECTIONS", "HOME_DIRECT_MAX_KEEPALIVE_CONNECTIONS",
        "HOME_DIRECT_KEEPALIVE_EXPIRY_SECONDS",
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
        f"ROUTE_DISCOVERY_URLS={merged.get('ROUTE_DISCOVERY_URLS', '')}",
        f"PEER_DISCOVERY_URLS={merged.get('PEER_DISCOVERY_URLS', '')}",
        f"FEDERATION_DISCOVERY_URLS={merged.get('FEDERATION_DISCOVERY_URLS', '')}",
        f"MIX_DISCOVERY_URLS={merged.get('MIX_DISCOVERY_URLS', '')}",
        f"NODE_REGISTRATION_DISCOVERY_URLS={merged.get('NODE_REGISTRATION_DISCOVERY_URLS', '')}",
        f"GATEWAY_DISCOVERY_URLS={merged.get('GATEWAY_DISCOVERY_URLS', node.discovery_node_url)}",
        f"GATEWAY_DISCOVERY_PUBLIC_URLS={merged.get('GATEWAY_DISCOVERY_PUBLIC_URLS', node.discovery_node_url)}",
        f"ROUTE_MINIMUM_DISCOVERY_SOURCES={merged.get('ROUTE_MINIMUM_DISCOVERY_SOURCES', str(node.discovery_minimum_sources))}",
        f"PEER_MINIMUM_DISCOVERY_SOURCES={merged.get('PEER_MINIMUM_DISCOVERY_SOURCES', str(node.discovery_minimum_sources))}",
        f"FEDERATION_MINIMUM_DISCOVERY_SOURCES={merged.get('FEDERATION_MINIMUM_DISCOVERY_SOURCES', str(node.discovery_minimum_sources))}",
        f"MIX_MINIMUM_DISCOVERY_SOURCES={merged.get('MIX_MINIMUM_DISCOVERY_SOURCES', str(node.discovery_minimum_sources))}",
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
        "# Ограничения транспортных соединений",
        f"RELAY_TRANSPORT_MODE={merged.get('RELAY_TRANSPORT_MODE', node.relay_transport_mode)}",
        f"RELAY_MAX_PERSISTENT_PEERS={merged.get('RELAY_MAX_PERSISTENT_PEERS', str(node.relay_max_persistent_peers))}",
        f"PEER_GUARD_COUNT={merged.get('PEER_GUARD_COUNT', str(node.peer_guard_count))}",
        f"PEER_ROTATING_COUNT={merged.get('PEER_ROTATING_COUNT', str(node.peer_rotating_count))}",
        f"PEER_RESERVE_COUNT={merged.get('PEER_RESERVE_COUNT', str(node.peer_reserve_count))}",
        f"RELAY_LINK_IDLE_SECONDS={merged.get('RELAY_LINK_IDLE_SECONDS', str(node.relay_link_idle_seconds))}",
        f"RELAY_WS_MAX_CONNECTIONS={merged.get('RELAY_WS_MAX_CONNECTIONS', str(node.relay_ws_max_connections))}",
        f"RELAY_WS_MAX_CONNECTIONS_PER_PEER={merged.get('RELAY_WS_MAX_CONNECTIONS_PER_PEER', str(node.relay_ws_max_connections_per_peer))}",
        f"HOME_DIRECT_MAX_CONNECTIONS={merged.get('HOME_DIRECT_MAX_CONNECTIONS', str(node.direct_max_connections))}",
        f"HOME_DIRECT_MAX_KEEPALIVE_CONNECTIONS={merged.get('HOME_DIRECT_MAX_KEEPALIVE_CONNECTIONS', str(node.direct_max_keepalive_connections))}",
        f"HOME_DIRECT_KEEPALIVE_EXPIRY_SECONDS={merged.get('HOME_DIRECT_KEEPALIVE_EXPIRY_SECONDS', str(node.direct_keepalive_expiry_seconds))}",
        "",
        f"HOME_NODE_ID={merged.get('HOME_NODE_ID', 'home-local')}",
        f"HOME_NODE_PUBLIC_URL={merged.get('HOME_NODE_PUBLIC_URL', node.home_node_public_url)}",
        f"STORAGE_NODE_URL={merged.get('STORAGE_NODE_URL', node.storage_node_url)}",
        f"JWT_SECRET={merged['JWT_SECRET']}",
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
        f"TURN_SHARED_SECRET={merged['TURN_SHARED_SECRET']}",
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


def _atomic_write_private(path: Path, contents: str) -> None:
    """Atomically replace a secret-bearing config with owner-only access."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            os.chmod(temporary.name, 0o600)
            temporary.write(contents)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


# Булевы настройки участия ноды в федерации — их тоже можно задать
# через окружение контейнера, а не только в .env
_BOOL_KEYS = frozenset({
    "NODE_PARTICIPATE_RELAY",
    "NODE_PARTICIPATE_STORAGE",
    "NODE_PARTICIPATE_WITNESS",
    "NODE_PARTICIPATE_MEDIA_CACHE",
    "NODE_PARTICIPATE_NAT_ASSIST",
})


def read_env_config() -> NodeEnvConfig:
    """
    Адреса сервисов для админки.

    Порядок приоритета: переменные окружения контейнера, затем файл .env.

    Это важно, когда одна и та же админка обслуживает разные стеки: в
    project/.env записаны имена контейнеров основного стека (discovery-node,
    home-node), а в msng-test они называются иначе (msng-discovery,
    msng-core-home). Без приоритета окружения админка ходила по именам из
    файла и получала «Name or service not known».

    Файл .env при этом остаётся источником для полей, которые панель
    редактирует — их в окружении обычно нет.
    """
    data = parse_env_file()  # пустой словарь, если файла нет

    def val(key: str, default: str) -> str:
        # Пустая строка в окружении считается «не задано»
        return os.environ.get(key) or data.get(key, default)

    try:
        owner_pct = int(val("OWNER_RESOURCE_PERCENT", "40"))
    except ValueError:
        owner_pct = 40
    owner_pct = max(0, min(100, owner_pct))

    def int_val(key: str, default: int, minimum: int, maximum: int) -> int:
        try:
            value = int(val(key, str(default)))
        except ValueError:
            value = default
        return max(minimum, min(maximum, value))

    # Для булевых полей окружение тоже главнее файла
    merged = {**data, **{k: v for k, v in os.environ.items() if k in _BOOL_KEYS}}

    return NodeEnvConfig(
        discovery_node_url=val("DISCOVERY_NODE_URL", "http://localhost:8003"),
        discovery_quorum_urls=val("ROUTE_DISCOVERY_URLS", ""),
        discovery_public_urls=val("GATEWAY_DISCOVERY_PUBLIC_URLS", ""),
        discovery_minimum_sources=int_val(
            "ROUTE_MINIMUM_DISCOVERY_SOURCES", 2, 2, 16
        ),
        cluster_id=val("CLUSTER_ID", "default"),
        node_resource_policy=val("NODE_RESOURCE_POLICY", "federated"),  # type: ignore[arg-type]
        home_node_public_url=val("HOME_NODE_URL", "") or val("HOME_NODE_PUBLIC_URL", "http://localhost:8001"),
        storage_node_url=val("STORAGE_NODE_URL", "http://localhost:8002"),
        media_node_public_url=val("MEDIA_NODE_URL", "") or val("MEDIA_NODE_PUBLIC_URL", "http://localhost:8004"),
        relay_node_public_url=val("RELAY_NODE_URL", "") or val("RELAY_NODE_PUBLIC_URL", "http://localhost:8005"),
        jwt_secret=val("JWT_SECRET", "") or None,
        discovery_admin_secret=val("DISCOVERY_ADMIN_SECRET", ""),
        owner_resource_percent=owner_pct,
        participate_relay=_env_bool(merged, "NODE_PARTICIPATE_RELAY", True),
        participate_storage=_env_bool(merged, "NODE_PARTICIPATE_STORAGE", True),
        participate_witness=_env_bool(merged, "NODE_PARTICIPATE_WITNESS", False),
        participate_media_cache=_env_bool(merged, "NODE_PARTICIPATE_MEDIA_CACHE", False),
        participate_nat_assist=_env_bool(merged, "NODE_PARTICIPATE_NAT_ASSIST", False),
        relay_transport_mode=val("RELAY_TRANSPORT_MODE", "http"),  # type: ignore[arg-type]
        relay_max_persistent_peers=int_val("RELAY_MAX_PERSISTENT_PEERS", 15, 1, 64),
        peer_guard_count=int_val("PEER_GUARD_COUNT", 2, 1, 5),
        peer_rotating_count=int_val("PEER_ROTATING_COUNT", 4, 0, 14),
        peer_reserve_count=int_val("PEER_RESERVE_COUNT", 2, 0, 15),
        relay_link_idle_seconds=int_val("RELAY_LINK_IDLE_SECONDS", 120, 10, 3600),
        relay_ws_max_connections=int_val("RELAY_WS_MAX_CONNECTIONS", 100, 1, 10000),
        relay_ws_max_connections_per_peer=int_val("RELAY_WS_MAX_CONNECTIONS_PER_PEER", 4, 1, 64),
        direct_max_connections=int_val("HOME_DIRECT_MAX_CONNECTIONS", 256, 8, 4096),
        direct_max_keepalive_connections=int_val(
            "HOME_DIRECT_MAX_KEEPALIVE_CONNECTIONS", 64, 0, 1024
        ),
        direct_keepalive_expiry_seconds=int_val(
            "HOME_DIRECT_KEEPALIVE_EXPIRY_SECONDS", 30, 1, 600
        ),
    )


def write_env_config(node: NodeEnvConfig) -> None:
    existing = _parse_env(ENV_PATH.read_text(encoding="utf-8")) if ENV_PATH.exists() else {}
    _atomic_write_private(ENV_PATH, _render_env(existing, node))


def read_storage_config() -> StorageConfigFile:
    if not STORAGE_CONFIG_PATH.exists():
        return StorageConfigFile()
    raw = json.loads(STORAGE_CONFIG_PATH.read_text(encoding="utf-8"))
    return StorageConfigFile.model_validate(raw)


def write_storage_config(storage: StorageConfigFile) -> None:
    _atomic_write_private(
        STORAGE_CONFIG_PATH,
        storage.model_dump_json(indent=2) + "\n",
    )


def read_full_config() -> FullAdminConfig:
    return FullAdminConfig(node=read_env_config(), storage=read_storage_config())


def write_full_config(config: FullAdminConfig) -> None:
    write_env_config(config.node)
    write_storage_config(config.storage)
