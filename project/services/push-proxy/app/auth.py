"""
Auth helpers:
  verify_node_secret   — shared secret для home-node → push-proxy
"""
import hmac

from fastapi import Header, HTTPException
from app.config import settings

async def verify_node_secret(x_push_secret: str = Header(..., alias="X-Push-Secret")) -> None:
    """
    Home-node передаёт shared secret в заголовке X-Push-Secret.
    Простая аутентификация для inter-service вызовов.
    """
    if not hmac.compare_digest(x_push_secret, settings.push_proxy_secret):
        raise HTTPException(status_code=403, detail="Invalid node secret")
