from typing import Any, Dict, Literal, Optional

from pydantic import BaseModel, Field


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
    cluster_id: str = "default"
    node_resource_policy: Literal["federated", "cluster", "local"] = "federated"
    home_node_public_url: str = "http://localhost:8001"
    storage_node_url: str = "http://localhost:8002"
    media_node_public_url: str = "http://localhost:8004"
    relay_node_public_url: str = "http://localhost:8005"
    jwt_secret: str = "dev-secret-change-me-in-production"
    lan_ip: str = "127.0.0.1"
    deploy_role: Literal["discovery", "home", "storage", "media", "relay", "turn", "all"] = "all"


class FullAdminConfig(BaseModel):
    node: NodeEnvConfig
    storage: StorageConfigFile
