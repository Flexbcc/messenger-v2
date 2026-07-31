import asyncio
import logging

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.routers import admin_enrollment, enrollment, registry
from app.config import ENROLLMENT_MODE, DISCOVERY_SIGNING_KEY_PATH
from app.attestation import ATTESTATION_MODE, MTLS_MODE
from app.deps import require_admin
from app.health import start_health_monitor
from app.key_rotation import bootstrap_key_from_file, get_all_valid_public_keys, rotate_signing_key, expire_old_keys
from app.record_signer import discovery_public_key_b64
from app.trust_degradation import start_trust_degradation

logger = logging.getLogger(__name__)

KEY_EXPIRE_CHECK_INTERVAL_SECONDS = 3600  # раз в час

app = FastAPI(title="Discovery Node", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)


async def _key_expire_loop():
    while True:
        await asyncio.sleep(KEY_EXPIRE_CHECK_INTERVAL_SECONDS)
        try:
            n = expire_old_keys()
            if n:
                logger.info("Key rotation: %d retiring key(s) marked expired", n)
        except Exception as e:
            logger.warning("Key expire check failed (non-fatal): %s", e)


@app.on_event("startup")
async def on_startup():
    init_db()
    bootstrap_key_from_file(DISCOVERY_SIGNING_KEY_PATH)
    start_health_monitor()
    start_trust_degradation()
    asyncio.create_task(_key_expire_loop())


@app.get("/health")
def health():
    with get_conn() as conn:
        nodes_count = conn.execute("SELECT COUNT(*) FROM node_capabilities").fetchone()[0]
        users_count = conn.execute("SELECT COUNT(*) FROM user_records").fetchone()[0]
    return {
        "status": "ok",
        "node_role": "discovery",
        "load": {
            "registered_nodes": nodes_count,
            "registered_users": users_count,
            "enrollment_mode": ENROLLMENT_MODE,
            "attestation_mode": ATTESTATION_MODE,
            "mtls_mode": MTLS_MODE,
        },
    }


@app.get("/discovery-pubkey")
def discovery_pubkey():
    """
    Ed25519 public key текущего активного ключа.
    Home-nodes используют для верификации подписей user records.
    """
    return {
        "public_key": discovery_public_key_b64(),
        "algorithm": "Ed25519",
        "encoding": "base64url",
        "usage": "verify user record signatures (user_id|home_node_url|updated_at)",
    }


@app.get("/discovery-pubkeys")
def discovery_pubkeys():
    """
    Все валидные публичные ключи (active + retiring в grace period).
    Home-nodes должны принимать подписи от любого из этих ключей.
    Используется при ротации ключей без даунтайма.
    """
    keys = get_all_valid_public_keys()
    return {
        "keys": [
            {
                "key_id": k["key_id"],
                "public_key": k["public_key"],
                "status": k["status"],
                "created_at": k["created_at"],
                "expires_at": k.get("expires_at"),
            }
            for k in keys
        ],
        "algorithm": "Ed25519",
        "encoding": "base64url",
    }


@app.post("/admin/discovery/rotate-key", dependencies=[Depends(require_admin)])
def rotate_discovery_key():
    """
    Ротация signing key без даунтайма:
      1. Новый ключ становится активным (подписывает новые записи).
      2. Старый переходит в retiring — ещё действителен KEY_ROTATION_GRACE_DAYS дней.
      3. После grace period старый ключ автоматически маркируется expired.

    Home-nodes получат новый ключ при следующем вызове /discovery-pubkeys.
    """
    result = rotate_signing_key()
    logger.info("Discovery signing key rotated: new key_id=%s", result["key_id"])
    return result


app.include_router(registry.router)
app.include_router(enrollment.router)
app.include_router(admin_enrollment.router)
