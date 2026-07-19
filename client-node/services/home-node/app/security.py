"""
Auth: Ed25519 challenge-response (spec/0300_CRYPTO.md, per-device) plus a
temporary identifier+password bridge (ADR-0007, argon2id — not a custom
primitive). JWT helper pattern ported from
~/secret_room/backend/app/core/security.py (ADR-0005); that file's weak
SHA-256 password hashing is NOT reused — argon2id is used instead.
"""
import base64
from datetime import datetime, timedelta
from typing import Optional

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from jose import jwt, JWTError
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from app.config import settings

_password_hasher = PasswordHasher()


def hash_password(password: str) -> str:
    return _password_hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return _password_hasher.verify(password_hash, password)
    except VerifyMismatchError:
        return False


def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    to_encode["exp"] = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
    return jwt.encode(to_encode, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def verify_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except JWTError:
        return None


def verify_ed25519_signature(public_key_b64: str, message: bytes, signature_b64: str) -> bool:
    try:
        pub_key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64))
        pub_key.verify(base64.b64decode(signature_b64), message)
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False
