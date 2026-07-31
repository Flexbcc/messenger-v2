"""
Auth helpers:
  verify_client_token  — JWT от home-node (клиент предъявляет его напрямую)
  verify_node_secret   — shared secret для home-node → push-proxy
"""
from fastapi import Header, HTTPException
from jose import jwt, JWTError

from app.config import settings


async def verify_client_token(authorization: str = Header(...)) -> str:
    """
    Проверяет JWT клиента (Bearer token, тот же что и к home-node).
    Push proxy не хранит JWT_SECRET — вместо этого принимает подписанный
    токен и доверяет подписи (asymmetric verify). Упрощение MVP: shared secret.

    Returns user_id (sub claim).
    """
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ")
    try:
        payload = jwt.decode(
            token,
            settings.push_proxy_secret,   # MVP: shared secret с home-node
            algorithms=["HS256"],
            options={"verify_exp": True},
        )
        user_id = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token: missing sub")
        return user_id
    except JWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}") from e


async def verify_node_secret(x_push_secret: str = Header(..., alias="X-Push-Secret")) -> None:
    """
    Home-node передаёт shared secret в заголовке X-Push-Secret.
    Простая аутентификация для inter-service вызовов.
    """
    if x_push_secret != settings.push_proxy_secret:
        raise HTTPException(status_code=403, detail="Invalid node secret")
