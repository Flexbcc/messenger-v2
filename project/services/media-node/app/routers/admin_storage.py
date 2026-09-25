import os
import hmac

from fastapi import APIRouter, Depends, Header, HTTPException

from app.config import settings as node_settings
from app.config_loader import reload_settings
from app.storage_service import purge_expired, run_backup

router = APIRouter(prefix="/admin", tags=["admin"])


def require_media_admin(
    supplied: str | None = Header(default=None, alias="X-Media-Admin-Secret"),
) -> None:
    expected = node_settings.admin_secret
    if not expected or not supplied or not hmac.compare_digest(supplied, expected):
        raise HTTPException(status_code=403, detail="Media admin authentication required")


@router.post("/reload-config", dependencies=[Depends(require_media_admin)])
def reload_config():
    reload_settings()
    purged = purge_expired()
    return {"status": "ok", "message": "storage.json перечитан", "purged_expired": purged}


@router.post("/backup", dependencies=[Depends(require_media_admin)])
def backup_now():
    home_db = node_settings.home_db_backup_path
    return run_backup(home_db_path=home_db if os.path.isfile(home_db) else None)
