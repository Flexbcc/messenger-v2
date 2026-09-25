"""JWT verification for auxiliary nodes (media, turn) — same secret as home-node."""
import uuid
from typing import Optional

from jose import JWTError, jwt


def verify_jwt_token(token: str, secret: str, algorithm: str = "HS256") -> Optional[dict]:
    if (
        algorithm != "HS256"
        or not secret
        or not token
        or len(token) > 8192
        or token.count(".") != 2
    ):
        return None
    try:
        payload = jwt.decode(token, secret, algorithms=["HS256"])
        if not isinstance(payload, dict):
            return None
        subject = payload.get("sub")
        device_id = payload.get("device_id")
        token_id = payload.get("jti")
        expires = payload.get("exp")
        if (
            not isinstance(subject, str)
            or not subject
            or len(subject) > 256
            or not isinstance(device_id, str)
            or not device_id
            or len(device_id) > 256
            or not isinstance(token_id, str)
            or len(token_id) != 36
            or not isinstance(expires, (int, float))
            or isinstance(expires, bool)
        ):
            return None
        if str(uuid.UUID(token_id)) != token_id:
            return None
        return payload
    except (JWTError, ValueError, TypeError):
        return None


def extract_bearer_token(authorization: Optional[str]) -> Optional[str]:
    if (
        not authorization
        or len(authorization) > 8200
        or not authorization.startswith("Bearer ")
    ):
        return None
    token = authorization.removeprefix("Bearer ").strip()
    if not token or any(character.isspace() for character in token):
        return None
    return token
