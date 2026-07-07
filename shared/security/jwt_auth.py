"""JWT verification for auxiliary nodes (media, turn) — same secret as home-node."""
from typing import Optional

from jose import JWTError, jwt


def verify_jwt_token(token: str, secret: str, algorithm: str = "HS256") -> Optional[dict]:
    if not secret or not token:
        return None
    try:
        return jwt.decode(token, secret, algorithms=[algorithm])
    except JWTError:
        return None


def extract_bearer_token(authorization: Optional[str]) -> Optional[str]:
    if not authorization or not authorization.startswith("Bearer "):
        return None
    return authorization.removeprefix("Bearer ").strip() or None
