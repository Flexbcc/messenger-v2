"""
Home-node → Push Proxy клиент.

Вызывается из fanout.py когда call_offer приходит для пользователя
который оффлайн (нет активного WS соединения).

Privacy: передаём только тип события и display_name звонящего.
Никаких SDP, ciphertext, ключей или истории — только wakeup сигнал.
"""
import logging

import httpx

from app.config import settings

_log = logging.getLogger(__name__)


async def notify_incoming_call(
    *,
    callee_user_id: str,
    caller_display_name: str | None,
    call_id: str,
) -> None:
    """
    Отправляет push уведомление получателю через push-proxy.
    Best-effort — не поднимает исключение если proxy недоступен.
    Вызывается только если PUSH_PROXY_URL задан в env.
    """
    url = settings.push_proxy_url
    if not url:
        return   # Push proxy не настроен — silent skip

    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.post(
                f"{url}/notify",
                json={
                    "user_id": callee_user_id,
                    "event": "incoming_call",
                    "caller_display_name": caller_display_name,
                    "call_id": call_id,
                },
                headers={"X-Push-Secret": settings.push_proxy_secret},
            )
            if resp.status_code not in (200, 204):
                _log.warning("Push proxy returned %s for user %s", resp.status_code, callee_user_id)
    except Exception as e:
        _log.warning("Push notify failed (non-fatal) for user %s: %s", callee_user_id, e)


async def notify_new_message(*, recipient_user_id: str) -> None:
    """Wake an offline PWA without disclosing sender or message content."""
    url = settings.push_proxy_url
    if not url:
        return
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            response = await client.post(
                f"{url}/notify",
                json={"user_id": recipient_user_id, "event": "new_message"},
                headers={"X-Push-Secret": settings.push_proxy_secret},
            )
            if response.status_code not in (200, 204):
                _log.warning(
                    "Push proxy returned %s for user %s",
                    response.status_code,
                    recipient_user_id,
                )
    except Exception as exc:
        _log.warning(
            "Message push failed (non-fatal) for user %s: %s",
            recipient_user_id,
            exc,
        )
