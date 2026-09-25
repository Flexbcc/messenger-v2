from typing import Any, Dict, Literal, Optional
from urllib.parse import urlsplit

from pydantic import BaseModel, Field, model_validator


class S3Config(BaseModel):
    enabled: bool = False
    endpoint_url: str = ""
    bucket: str = ""
    access_key: str = ""
    secret_key: str = ""
    region: str = "us-east-1"
    prefix: str = ""


class MediaStorageConfig(BaseModel):
    primary_backend: Literal["local", "s3"] = "local"
    local_path: str = "/data/media_blobs"
    s3: S3Config = Field(default_factory=S3Config)
    network_cache_ttl_hours: int = 48


class PersonalCloudConfig(BaseModel):
    enabled: bool = True
    default_for_node_users: Literal["operator", "personal"] = "operator"
    allow_user_personal_s3: bool = True
    users: Dict[str, Dict[str, Any]] = Field(default_factory=dict)


class BackupConfig(BaseModel):
    enabled: bool = False
    backend: Literal["local", "s3"] = "local"
    local_path: str = "/data/backups"
    schedule_hours: int = 24
    include_media: bool = True
    include_home_db: bool = True
    s3: S3Config = Field(default_factory=lambda: S3Config(prefix="backups/"))


class StorageConfigFile(BaseModel):
    media: MediaStorageConfig = Field(default_factory=MediaStorageConfig)
    personal_cloud: PersonalCloudConfig = Field(default_factory=PersonalCloudConfig)
    backup: BackupConfig = Field(default_factory=BackupConfig)


class NodeEnvConfig(BaseModel):
    discovery_node_url: str = "http://localhost:8003"
    discovery_quorum_urls: str = ""
    discovery_public_urls: str = ""
    discovery_minimum_sources: int = Field(default=2, ge=2, le=16)
    cluster_id: str = "default"
    node_resource_policy: Literal["federated", "cluster", "local"] = "federated"
    home_node_public_url: str = "http://localhost:8001"
    storage_node_url: str = "http://localhost:8002"
    media_node_public_url: str = "http://localhost:8004"
    relay_node_public_url: str = "http://localhost:8005"
    jwt_secret: Optional[str] = None
    # Секрет admin API discovery. Нужен для операций реестра:
    # список нод, approve/suspend, trust level, журнал аудита.
    # Discovery ждёт его в заголовке X-Discovery-Admin-Secret.
    discovery_admin_secret: Optional[str] = None
    lan_ip: str = "127.0.0.1"
    deploy_role: Literal["discovery", "home", "storage", "media", "relay", "turn", "all"] = "all"
    # Owner-first capacity split (rest goes to network help).
    owner_resource_percent: int = Field(default=40, ge=0, le=100)
    # Network participation opt-ins.
    participate_relay: bool = True
    participate_storage: bool = True
    participate_witness: bool = False
    participate_media_cache: bool = False
    participate_nat_assist: bool = False
    relay_transport_mode: Literal[
        "http", "websocket-preferred", "websocket-required",
        "quic-preferred", "quic-required",
    ] = "http"
    relay_max_persistent_peers: int = Field(default=15, ge=1, le=64)
    peer_guard_count: int = Field(default=2, ge=1, le=5)
    peer_rotating_count: int = Field(default=4, ge=0, le=14)
    peer_reserve_count: int = Field(default=2, ge=0, le=15)
    relay_link_idle_seconds: int = Field(default=120, ge=10, le=3600)
    relay_ws_max_connections: int = Field(default=100, ge=1, le=10000)
    relay_ws_max_connections_per_peer: int = Field(default=4, ge=1, le=64)
    direct_max_connections: int = Field(default=256, ge=8, le=4096)
    direct_max_keepalive_connections: int = Field(default=64, ge=0, le=1024)
    direct_keepalive_expiry_seconds: int = Field(default=30, ge=1, le=600)

    @model_validator(mode="after")
    def validate_connection_limits(self):
        if self.direct_max_keepalive_connections > self.direct_max_connections:
            raise ValueError("Home keep-alive limit cannot exceed the total Home connection limit")
        if self.relay_ws_max_connections_per_peer > self.relay_ws_max_connections:
            raise ValueError("per-peer WSS limit cannot exceed the total Relay WSS limit")
        active_peers = self.peer_guard_count + self.peer_rotating_count
        if not 5 <= active_peers <= 15:
            raise ValueError("active guard + rotating peer target must be between 5 and 15")
        if active_peers > self.relay_max_persistent_peers:
            raise ValueError("active peer target cannot exceed the persistent Relay limit")
        if self.discovery_quorum_urls.strip():
            origins = []
            for raw in self.discovery_quorum_urls.split(","):
                value = raw.strip().rstrip("/")
                parsed = urlsplit(value)
                if (
                    parsed.scheme not in {"http", "https"}
                    or not parsed.hostname
                    or parsed.username
                    or parsed.password
                    or parsed.path not in {"", "/"}
                    or parsed.query
                    or parsed.fragment
                ):
                    raise ValueError("Discovery quorum entries must be plain HTTP(S) origins")
                origins.append(value)
            unique = list(dict.fromkeys(origins))
            if len(unique) < self.discovery_minimum_sources:
                raise ValueError("Discovery quorum needs at least the configured number of sources")
        if self.discovery_public_urls.strip():
            for raw in self.discovery_public_urls.split(","):
                value = raw.strip().rstrip("/")
                parsed = urlsplit(value)
                if (
                    parsed.scheme not in {"http", "https"}
                    or not parsed.hostname
                    or parsed.username
                    or parsed.password
                    or parsed.path not in {"", "/"}
                    or parsed.query
                    or parsed.fragment
                ):
                    raise ValueError("Public Discovery entries must be plain HTTP(S) origins")
        return self



class FullAdminConfig(BaseModel):
    node: NodeEnvConfig
    storage: StorageConfigFile
