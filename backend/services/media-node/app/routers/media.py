from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import Response

from app.config import settings
from app.media_auth import require_media_download, require_media_upload
from app.storage_service import load_blob, save_blob

router = APIRouter()

MAX_UPLOAD_BYTES = settings.max_upload_bytes


@router.post("/media")
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    owner_user_id: str | None = Form(default=None),
    tier: str = Form(default="primary"),
    _auth: str = Depends(require_media_upload),
):
    """
    Client uploads an already-encrypted blob.

    - tier=primary — permanent (operator disk/S3 or recipient personal cloud)
    - tier=network_cache — TTL copy for federated access (see storage.json)
    - owner_user_id — recipient; used for personal cloud routing
    """
    if tier not in ("primary", "network_cache"):
        raise HTTPException(status_code=400, detail="tier must be primary or network_cache")

    data = await file.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="File too large")

    media_id, backend, expires_at = save_blob(data, owner_user_id=owner_user_id, tier=tier)
    return {
        "media_id": media_id,
        "size": len(data),
        "backend": backend,
        "tier": tier,
        "expires_at": expires_at,
    }


@router.get("/media/{media_id}")
async def download_media(media_id: str, request: Request):
    await require_media_download(request, media_id)
    data = load_blob(media_id)
    if data is None:
        raise HTTPException(status_code=404, detail="Not found or cache expired")
    return Response(content=data, media_type="application/octet-stream")
