from typing import Optional

from app.backends.local import LocalDiskBackend
from app.backends.s3 import S3Backend
from app.config_loader import S3Settings, StorageSettings, get_settings


def backend_for_s3(cfg: S3Settings) -> S3Backend:
    if not cfg.bucket:
        raise ValueError("S3 bucket is required")
    return S3Backend(cfg)


def primary_media_backend(settings: Optional[StorageSettings] = None) -> LocalDiskBackend | S3Backend:
    s = settings or get_settings()
    m = s.media
    if m.primary_backend == "s3" and m.s3.enabled:
        return backend_for_s3(m.s3)
    return LocalDiskBackend(m.local_path)


def personal_backend_for_user(user_id: str, settings: Optional[StorageSettings] = None):
    s = settings or get_settings()
    if not s.personal_cloud.enabled:
        return None
    profile = s.personal_cloud.users.get(user_id)
    if not profile:
        return None
    if profile.get("backend") == "s3" and profile.get("s3"):
        raw = profile["s3"]
        cfg = S3Settings(
            enabled=True,
            endpoint_url=raw.get("endpoint_url", ""),
            bucket=raw.get("bucket", ""),
            access_key=raw.get("access_key", ""),
            secret_key=raw.get("secret_key", ""),
            region=raw.get("region", "us-east-1"),
            prefix=raw.get("prefix", f"users/{user_id}/"),
        )
        return backend_for_s3(cfg)
    if profile.get("backend") == "local" and profile.get("local_path"):
        return LocalDiskBackend(profile["local_path"])
    return None


def backup_backend(settings: Optional[StorageSettings] = None):
    s = settings or get_settings()
    b = s.backup
    if not b.enabled:
        return None
    if b.backend == "s3" and b.s3.enabled:
        return backend_for_s3(b.s3)
    return LocalDiskBackend(b.local_path)
