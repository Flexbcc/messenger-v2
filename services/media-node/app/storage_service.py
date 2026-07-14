"""
Media blob storage with primary / network-cache tiers and optional personal cloud.

- primary: permanent on operator or user's personal backend
- network_cache: shared TTL copy for federated access (default 48h)
"""
import hashlib
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional, Tuple

from app.backends.factory import backup_backend, personal_backend_for_user, primary_media_backend
from app.config_loader import get_settings, reload_settings
from app.db import get_conn, init_db


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _resolve_backends(owner_user_id: Optional[str], tier: str):
    settings = get_settings()
    primary = primary_media_backend(settings)

    if tier == "network_cache":
        return primary, primary.name

    personal = None
    if owner_user_id and settings.personal_cloud.enabled:
        from app.home_storage_profile import fetch_user_storage_profile_sync, home_storage_profiles_enabled

        has_profile = owner_user_id in settings.personal_cloud.users
        if home_storage_profiles_enabled():
            has_profile = has_profile or fetch_user_storage_profile_sync(owner_user_id) is not None
        use_personal = settings.personal_cloud.default_for_node_users == "personal" or has_profile
        if use_personal:
            personal = personal_backend_for_user(owner_user_id, settings)

    if personal:
        return personal, personal.name
    return primary, primary.name


def save_blob(
    data: bytes,
    *,
    owner_user_id: Optional[str] = None,
    tier: str = "primary",
) -> Tuple[str, str, Optional[str]]:
    """
    Returns (media_id, backend_name, expires_at_iso).
    Content-addressed id = sha256(ciphertext).
    """
    init_db()
    digest = hashlib.sha256(data).hexdigest()
    backend, backend_name = _resolve_backends(owner_user_id, tier)
    backend.put(digest, data)

    settings = get_settings()
    expires_at = None
    if tier == "network_cache":
        hours = settings.media.network_cache_ttl_hours
        expires_at = (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()

    # Keep operator copy when personal cloud is primary (family node + user S3).
    if tier == "primary" and owner_user_id:
        personal = personal_backend_for_user(owner_user_id)
        op = primary_media_backend()
        if personal and personal is not op and not op.exists(digest):
            op.put(digest, data)

    now = _now_iso()
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO media_objects (media_id, owner_user_id, tier, backend, object_key, size_bytes, created_at, expires_at, last_access_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_id) DO UPDATE SET
                last_access_at=excluded.last_access_at,
                expires_at=COALESCE(excluded.expires_at, media_objects.expires_at)
            """,
            (digest, owner_user_id, tier, backend_name, digest, len(data), now, expires_at, now),
        )
        conn.commit()
    return digest, backend_name, expires_at


def load_blob(media_id: str) -> Optional[bytes]:
    init_db()
    purge_expired()
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM media_objects WHERE media_id = ?", (media_id,)).fetchone()
    if not row:
        return _legacy_load(media_id)

    if row["expires_at"]:
        exp = datetime.fromisoformat(row["expires_at"])
        if datetime.now(timezone.utc) > exp:
            return None

    backend_name = row["backend"]
    settings = get_settings()
    if backend_name == "s3":
        from app.backends.factory import backend_for_s3

        if row["tier"] == "network_cache" or not row["owner_user_id"]:
            backend = backend_for_s3(settings.media.s3)
        else:
            personal = personal_backend_for_user(row["owner_user_id"])
            backend = personal or backend_for_s3(settings.media.s3)
    else:
        personal = personal_backend_for_user(row["owner_user_id"]) if row["owner_user_id"] else None
        backend = personal or primary_media_backend(settings)

    data = backend.get(row["object_key"])
    if data is not None:
        with get_conn() as conn:
            conn.execute(
                "UPDATE media_objects SET last_access_at = ? WHERE media_id = ?",
                (_now_iso(), media_id),
            )
            conn.commit()
    return data


def _legacy_load(media_id: str) -> Optional[bytes]:
    """Fallback for blobs stored before metadata table."""
    backend = primary_media_backend()
    return backend.get(media_id)


def purge_expired() -> int:
    init_db()
    now = _now_iso()
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT media_id, object_key, backend, tier FROM media_objects WHERE expires_at IS NOT NULL AND expires_at < ?",
            (now,),
        ).fetchall()
        for row in rows:
            try:
                if row["backend"] == "local":
                    primary_media_backend().delete(row["object_key"])
            except OSError:
                pass
            conn.execute("DELETE FROM media_objects WHERE media_id = ?", (row["media_id"],))
        conn.commit()
    return len(rows)


def run_backup(home_db_path: Optional[str] = None) -> dict:
    settings = get_settings()
    if not settings.backup.enabled:
        return {"status": "skipped", "reason": "backup disabled"}

    dest = backup_backend(settings)
    if dest is None:
        return {"status": "skipped", "reason": "no backup backend"}

    files = 0
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    media_backend = primary_media_backend()

    with get_conn() as conn:
        rows = conn.execute("SELECT media_id, object_key FROM media_objects WHERE tier != 'network_cache' OR expires_at IS NULL").fetchall()

    for row in rows:
        data = media_backend.get(row["object_key"])
        if data is None:
            continue
        key = f"{ts}/media/{row['media_id']}"
        dest.put(key, data)
        files += 1

    if settings.backup.include_home_db and home_db_path and Path(home_db_path).is_file():
        key = f"{ts}/home/home.db"
        dest.put(key, Path(home_db_path).read_bytes())
        files += 1

    return {
        "status": "ok",
        "files": files,
        "destination": getattr(dest, "root", settings.backup.local_path),
        "timestamp": ts,
    }
