"""Load config/storage.json — same file the Admin GUI writes."""
import json
import os
from dataclasses import dataclass, field
from typing import Any, Dict, Optional


@dataclass
class S3Settings:
    enabled: bool = False
    endpoint_url: str = ""
    bucket: str = ""
    access_key: str = ""
    secret_key: str = ""
    region: str = "us-east-1"
    prefix: str = ""


@dataclass
class MediaSettings:
    primary_backend: str = "local"
    local_path: str = "/data/media_blobs"
    s3: S3Settings = field(default_factory=S3Settings)
    network_cache_ttl_hours: int = 48


@dataclass
class PersonalCloudSettings:
    enabled: bool = True
    default_for_node_users: str = "operator"
    allow_user_personal_s3: bool = True
    users: Dict[str, Any] = field(default_factory=dict)


@dataclass
class BackupSettings:
    enabled: bool = False
    backend: str = "local"
    local_path: str = "/data/backups"
    schedule_hours: int = 24
    include_media: bool = True
    include_home_db: bool = True
    s3: S3Settings = field(default_factory=lambda: S3Settings(prefix="backups/"))


@dataclass
class StorageSettings:
    media: MediaSettings = field(default_factory=MediaSettings)
    personal_cloud: PersonalCloudSettings = field(default_factory=PersonalCloudSettings)
    backup: BackupSettings = field(default_factory=BackupSettings)


def _s3_from_dict(d: dict) -> S3Settings:
    return S3Settings(
        enabled=bool(d.get("enabled")),
        endpoint_url=d.get("endpoint_url", ""),
        bucket=d.get("bucket", ""),
        access_key=d.get("access_key", ""),
        secret_key=d.get("secret_key", ""),
        region=d.get("region", "us-east-1"),
        prefix=d.get("prefix", ""),
    )


def load_storage_settings() -> StorageSettings:
    path = os.environ.get("STORAGE_CONFIG", "/project/config/storage.json")
    if not os.path.isfile(path):
        return StorageSettings()
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    media = raw.get("media", {})
    personal = raw.get("personal_cloud", {})
    backup = raw.get("backup", {})
    return StorageSettings(
        media=MediaSettings(
            primary_backend=media.get("primary_backend", "local"),
            local_path=media.get("local_path", os.environ.get("MEDIA_STORAGE_DIR", "/data/media_blobs")),
            s3=_s3_from_dict(media.get("s3", {})),
            network_cache_ttl_hours=int(media.get("network_cache_ttl_hours", 48)),
        ),
        personal_cloud=PersonalCloudSettings(
            enabled=bool(personal.get("enabled", True)),
            default_for_node_users=personal.get("default_for_node_users", "operator"),
            allow_user_personal_s3=bool(personal.get("allow_user_personal_s3", True)),
            users=personal.get("users", {}),
        ),
        backup=BackupSettings(
            enabled=bool(backup.get("enabled")),
            backend=backup.get("backend", "local"),
            local_path=backup.get("local_path", "/data/backups"),
            schedule_hours=int(backup.get("schedule_hours", 24)),
            include_media=bool(backup.get("include_media", True)),
            include_home_db=bool(backup.get("include_home_db", True)),
            s3=_s3_from_dict(backup.get("s3", {})),
        ),
    )


_settings: Optional[StorageSettings] = None


def get_settings() -> StorageSettings:
    global _settings
    if _settings is None:
        _settings = load_storage_settings()
    return _settings


def reload_settings() -> StorageSettings:
    global _settings
    _settings = load_storage_settings()
    return _settings
