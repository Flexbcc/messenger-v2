from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, Path, Request, UploadFile
from fastapi.responses import Response

from app.config import settings
from app.media_auth import require_media_download, require_media_upload
from app.storage_service import load_blob, save_blob
from shared.security.config import HDR_NODE_ID, HDR_NONCE, HDR_SIGNATURE, HDR_TIMESTAMP
from shared.security.media_id import MEDIA_ID_PATTERN

router = APIRouter()

MAX_UPLOAD_BYTES = settings.max_upload_bytes
_UPLOAD_CHUNK_BYTES = 64 * 1024


def _is_federation_request(request: Request) -> bool:
    return all(
        request.headers.get(header)
        for header in (HDR_NODE_ID, HDR_TIMESTAMP, HDR_NONCE, HDR_SIGNATURE)
    )


async def _read_bounded_upload(file: UploadFile) -> bytes:
    data = bytearray()
    while True:
        chunk = await file.read(_UPLOAD_CHUNK_BYTES)
        if not chunk:
            return bytes(data)
        if len(data) + len(chunk) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="File too large")
        data.extend(chunk)


@router.post("/media")
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    owner_user_id: str | None = Form(default=None),
    tier: str = Form(default="network_cache"),
    _auth: str = Depends(require_media_upload),
):
    """
    Client uploads an already-encrypted blob.

    - tier=primary — explicit permanent operator/personal storage
    - tier=network_cache — TTL copy for federated access (see storage.json)
    - owner_user_id — recipient; used for personal cloud routing
    """
    if tier not in ("primary", "network_cache"):
        raise HTTPException(status_code=400, detail="tier must be primary or network_cache")

    if owner_user_id is not None:
        owner_user_id = owner_user_id.strip()
        if not owner_user_id or len(owner_user_id) > 128:
            raise HTTPException(status_code=400, detail="Invalid owner_user_id")
        if not _is_federation_request(request) and owner_user_id != _auth:
            raise HTTPException(status_code=403, detail="Media owner does not match token subject")

    data = await _read_bounded_upload(file)

    media_id, backend, expires_at = save_blob(data, owner_user_id=owner_user_id, tier=tier)
    return {
        "media_id": media_id,
        "size": len(data),
        "backend": backend,
        "tier": tier,
        "expires_at": expires_at,
    }


@router.get("/media/{media_id}")
async def download_media(
    media_id: Annotated[str, Path(pattern=MEDIA_ID_PATTERN)], request: Request
):
    await require_media_download(request, media_id)
    data = load_blob(media_id)
    if data is None:
        raise HTTPException(status_code=404, detail="Not found or cache expired")
    return Response(content=data, media_type="application/octet-stream")
