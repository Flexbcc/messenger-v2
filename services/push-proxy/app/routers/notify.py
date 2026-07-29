"""
Notify endpoint — вызывается home-node при call_offer для offline получателя.

POST /notify   — отправить push для конкретного user_id
"""
import logging

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel

from app.auth import verify_node_secret
from app.db import get_db
from app.push import send_push

_log = logging.getLogger(__name__)
router = APIRouter(prefix="/notify", tags=["notify"])


class NotifyRequest(BaseModel):
    user_id: str
    # Тип события — минимальный payload для privacy
    event: str = "incoming_call"   # incoming_call | missed_call | new_message
    # Опциональные метаданные — только то что нужно для wakeup.
    # НЕ содержит SDP, ключей или текста сообщений.
    caller_display_name: str | None = None
    call_id: str | None = None


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
    async with db.execute(
        "SELECT device_id, platform, token FROM push_tokens WHERE user_id=?",
        (payload.user_id,),
    ) as cursor:
        rows = await cursor.fetchall()

    if not rows:
        _log.debug("No push tokens for user_id=%s", payload.user_id)
        return

    push_data = {
        "type": payload.event,
        "call_id": payload.call_id,
        "caller": payload.caller_display_name,
    }
    # Убираем None значения
    push_data = {k: v for k, v in push_data.items() if v is not None}

    for row in rows:
        try:
            await send_push(
                platform=row["platform"],
                token=row["token"],
                data=push_data,
            )
            _log.info("Push sent: user=%s device=%s platform=%s event=%s",
                      payload.user_id, row["device_id"], row["platform"], payload.event)
        except Exception as e:
            _log.warning("Push failed: user=%s device=%s: %s",
                         payload.user_id, row["device_id"], e)
