"""
Home-node → Push Proxy клиент.

Вызывается из fanout.py когда call_offer приходит для пользователя
который оффлайн (нет активного WS соединения).

Privacy: передаём только тип события и непрозрачный идентификатор звонка.
Никаких имён, SDP, ciphertext, ключей или истории — только wakeup сигнал.
"""
import logging

import httpx

from app.config import settings

_log = logging.getLogger(__name__)


async def _send_wakeup(*, user_id: str, payload: dict[str, str]) -> None:
    url = settings.push_proxy_url
    if not url:
        return
    try:
        async with httpx.AsyncClient(
            timeout=5,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            # The notify response has no payload contract. Streaming avoids
            # buffering a malicious or misconfigured proxy response body.
            async with client.stream(
                "POST",
                f"{url}/notify",
                json={"user_id": user_id, **payload},
                headers={"X-Push-Secret": settings.push_proxy_secret},
            ) as response:
                if response.status_code not in (200, 204):
                    _log.warning(
                        "Push proxy returned %s for user %s",
                        response.status_code,
                        user_id,
                    )
    except Exception as exc:  # best-effort wakeup must not break message fanout
        _log.warning(
            "Push notify failed (non-fatal) for user %s: %s",
            user_id,
            type(exc).__name__,
        )


async def notify_incoming_call(
    *,
    callee_user_id: str,
    call_id: str,
) -> None:
    """
    Отправляет push уведомление получателю через push-proxy.
    Best-effort — не поднимает исключение если proxy недоступен.
    Вызывается только если PUSH_PROXY_URL задан в env.
    """
    await _send_wakeup(
        user_id=callee_user_id,
        payload={"event": "incoming_call", "call_id": call_id},
    )


async def notify_new_message(*, recipient_user_id: str) -> None:
    """Wake an offline PWA without disclosing sender or message content."""
    await _send_wakeup(
        user_id=recipient_user_id,
        payload={"event": "new_message"},
    )
