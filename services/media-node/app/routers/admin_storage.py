import os

from fastapi import APIRouter

from app.config_loader import get_settings, reload_settings
from app.storage_service import purge_expired, run_backup

router = APIRouter(prefix="/admin", tags=["admin"])


@router.post("/reload-config")
def reload_config():
    reload_settings()
    purged = purge_expired()
    return {"status": "ok", "message": "storage.json перечитан", "purged_expired": purged}


@router.post("/backup")
def backup_now():
    home_db = os.environ.get("HOME_DB_BACKUP_PATH", "/data/home/home.db")
    return run_backup(home_db_path=home_db if os.path.isfile(home_db) else None)
