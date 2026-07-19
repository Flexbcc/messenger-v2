"""Self-registration + heartbeat with Discovery Control Plane (ADR-0006, ADR-0009)."""
import asyncio
import logging
import os
from pathlib import Path
from typing import Optional

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

HEARTBEAT_INTERVAL_SECONDS = 60
ENROLLMENT_POLL_INTERVAL_SECONDS = 30
REGISTER_RETRY_INITIAL_SECONDS = 2
REGISTER_RETRY_MAX_SECONDS = 30


def _read_secret_file(path: str) -> Optional[str]:
    try:
        text = Path(path).read_text(encoding="utf-8").strip()
        return text or None
    except FileNotFoundError:
        return None


def _write_secret_file(path: str, value: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(value.strip(), encoding="utf-8")
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass


def _load_node_token() -> Optional[str]:
    return _read_secret_file(settings.node_token_path)


def _load_enrollment_secret() -> Optional[str]:
    return _read_secret_file(settings.enrollment_secret_path)


def _save_enrollment_secret(secret: str) -> None:
    _write_secret_file(settings.enrollment_secret_path, secret)
    logger.info("Enrollment secret saved to %s", settings.enrollment_secret_path)


def _save_node_token(token: str) -> None:
    _write_secret_file(settings.node_token_path, token)
    logger.info("Node token saved to %s", settings.node_token_path)


def _auth_headers() -> dict:
    token = _load_node_token()
    if token:
        return {"Authorization": f"Bearer {token}"}
    return {}


def _enrollment_active() -> bool:
    if settings.enrollment_mode == "legacy":
        return False
    return _load_enrollment_secret() is not None and _load_node_token() is None


def _attestation_payload() -> dict:
    payload = {}
    if settings.build_hash:
        payload["build_hash"] = settings.build_hash
    if settings.tls_cert_fingerprint:
        payload["tls_cert_fingerprint"] = settings.tls_cert_fingerprint
    if settings.release_signature:
        payload["release_signature"] = settings.release_signature
    return payload


async def _register_once() -> dict:
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.post(
            f"{settings.discovery_url}/registry/nodes",
            json={
                "node_id": settings.node_id,
                "node_url": settings.public_url,
                "capabilities": settings.capabilities,
                "software_version": settings.software_version,
                "cluster_id": settings.cluster_id,
                **_attestation_payload(),
            },
        )
        resp.raise_for_status()
        data = resp.json()
    secret = data.get("enrollment_secret")
    if secret:
        _save_enrollment_secret(secret)
    if data.get("trust_status") == "pending":
        logger.info("Enrollment pending admin approval for node_id=%s", settings.node_id)
    return data


async def _enrollment_poll_once() -> Optional[str]:
    secret = _load_enrollment_secret()
    if not secret:
        return None
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.post(
            f"{settings.discovery_url}/registry/enrollment/status",
            json={"node_id": settings.node_id, "enrollment_secret": secret},
        )
    if resp.status_code in (403, 404):
        return None
    if resp.status_code >= 400:
        resp.raise_for_status()
    data = resp.json()
    token = data.get("node_token")
    if token:
        _save_node_token(token)
        logger.info("Enrollment complete — node_token claimed")
        return token
    trust = data.get("trust_status")
    if trust == "pending":
        logger.debug("Enrollment still pending approval")
    elif trust not in ("trusted",):
        logger.warning("Enrollment trust_status=%s: %s", trust, data.get("message"))
    return None


async def _enrollment_poll_loop() -> None:
    while _enrollment_active():
        try:
            await _enrollment_poll_once()
        except Exception as e:
            logger.warning("Enrollment poll failed: %s", e)
        if not _enrollment_active():
            break
        await asyncio.sleep(ENROLLMENT_POLL_INTERVAL_SECONDS)


async def _register_with_retry() -> None:
    delay = REGISTER_RETRY_INITIAL_SECONDS
    while True:
        try:
            await _register_once()
            return
        except Exception as e:
            logger.warning("Registration with discovery failed (retrying in %ss): %s", delay, e)
            await asyncio.sleep(delay)
            delay = min(delay * 2, REGISTER_RETRY_MAX_SECONDS)


async def _heartbeat_once() -> None:
    async with httpx.AsyncClient(timeout=5.0) as client:
        resp = await client.post(
            f"{settings.discovery_url}/registry/nodes/{settings.node_id}/heartbeat",
            json=_attestation_payload(),
            headers=_auth_headers(),
        )
        if resp.status_code == 404:
            await _register_once()
            return
        if resp.status_code == 403:
            await _enrollment_poll_once()
            return
        if resp.status_code == 401:
            logger.warning("Heartbeat rejected — invalid or missing node_token")
            return
        resp.raise_for_status()


async def _heartbeat_loop() -> None:
    while True:
        await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)
        try:
            await _heartbeat_once()
        except Exception as e:
            logger.warning("Heartbeat to discovery failed: %s", e)


def start_node_registration() -> None:
    async def _init():
        await _register_with_retry()
        if _enrollment_active():
            asyncio.create_task(_enrollment_poll_loop())
        asyncio.create_task(_heartbeat_loop())

    asyncio.create_task(_init())
