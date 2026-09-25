"""
Notify endpoint — вызывается home-node при call_offer для offline получателя.

POST /notify   — отправить push для конкретного user_id
"""
import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.auth import verify_node_secret
from app.db import db_write_lock, get_db
from app.limits import MAX_CONCURRENT_PROVIDER_REQUESTS, MAX_PUSH_DEVICES_PER_USER
from app.push import send_push
from app.token_crypto import TokenDecryptionError, decrypt_push_token

_log = logging.getLogger(__name__)
router = APIRouter(prefix="/notify", tags=["notify"])


class NotifyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    user_id: str = Field(min_length=1, max_length=128)
    # Тип события — минимальный payload для privacy
    event: Literal["incoming_call", "missed_call", "new_message"] = "incoming_call"
    # Опциональные метаданные — только то что нужно для wakeup.
    # НЕ содержит SDP, ключей или текста сообщений.
    call_id: str | None = Field(default=None, min_length=1, max_length=128)


@router.post("", status_code=204)
async def notify(
    payload: NotifyRequest,
    _: None = Depends(verify_node_secret),
    db=Depends(get_db),
):
    """
    Home-node вызывает этот endpoint когда обнаруживает что получатель
    call_offer оффлайн или в background. Push proxy рассылает silent push
    на все зарегистрированные устройства пользователя.

    Privacy: payload push уведомления не содержит контент чата или ключи.
    Клиент после wakeup подключается через WS и получает signal через E2EE.
    """
    failures = 0
    valid_tokens: list[tuple[str, str]] = []
    async with db_write_lock:
        async with db.execute(
            "SELECT device_id, platform, token FROM push_tokens "
            "WHERE user_id=? ORDER BY device_id LIMIT ?",
            (payload.user_id, MAX_PUSH_DEVICES_PER_USER + 1),
        ) as cursor:
            rows = await cursor.fetchall()

        if not rows:
            _log.debug("No registered push tokens for requested recipient")
            return
        if len(rows) > MAX_PUSH_DEVICES_PER_USER:
            _log.warning("Push token count exceeds per-user safety limit")
            raise HTTPException(status_code=503, detail="Too many registered push devices")

        for row in rows:
            try:
                token = decrypt_push_token(row["token"])
            except TokenDecryptionError:
                failures += 1
                await db.execute(
                    "DELETE FROM push_tokens WHERE user_id=? AND device_id=?",
                    (payload.user_id, row["device_id"]),
                )
                _log.warning("Removed unreadable or legacy plaintext push token")
                continue
            valid_tokens.append((row["platform"], token))
        await db.commit()

    # Never copy sender identity or message content into a third-party push
    # service. Push is only a wake-up hint; details arrive over E2EE transport.
    push_data = {"type": payload.event, "call_id": payload.call_id}
    push_data = {key: value for key, value in push_data.items() if value is not None}

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_PROVIDER_REQUESTS)

    async def deliver(platform: str, token: str) -> bool:
        try:
            async with semaphore:
                await send_push(platform=platform, token=token, data=push_data)
            _log.info("Push delivered platform=%s event=%s", platform, payload.event)
            return True
        except Exception:
            _log.warning("Push provider delivery failed platform=%s", platform)
            return False

    outcomes = await asyncio.gather(
        *(deliver(platform, token) for platform, token in valid_tokens)
    )
    delivered = sum(outcomes)
    failures += len(outcomes) - delivered

    if delivered == 0:
        raise HTTPException(
            status_code=503,
            detail=f"Push delivery unavailable for {failures} registered device(s)",
        )
