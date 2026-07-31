"""
Auth: Ed25519 challenge-response (spec/0300_CRYPTO.md, per-device) plus a
temporary identifier+password bridge (ADR-0007, argon2id — not a custom
primitive). JWT helper pattern ported from
~/secret_room/backend/app/core/security.py (ADR-0005); that file's weak
SHA-256 password hashing is NOT reused — argon2id is used instead.

JWT revocation: каждый токен содержит `jti` (uuid4). При logout jti
записывается в таблицу `revoked_tokens` (SQLite). `deps.py` проверяет jti
перед каждым запросом. Истёкшие записи чистятся при каждой проверке +
фоновым задачей в main.py.
"""
import base64
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from jose import jwt, JWTError
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

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
    to_encode["jti"] = str(uuid.uuid4())
    to_encode["exp"] = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
    return jwt.encode(to_encode, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def verify_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except JWTError:
        return None


# ---------------------------------------------------------------------------
# Revocation store (SQLite)
# ---------------------------------------------------------------------------

async def _ensure_revoked_table(db: AsyncSession) -> None:
    await db.execute(text("""
        CREATE TABLE IF NOT EXISTS revoked_tokens (
            jti TEXT PRIMARY KEY,
            expires_at TEXT NOT NULL
        )
    """))
    await db.commit()


async def revoke_token(db: AsyncSession, jti: str, expires_at: datetime) -> None:
    """Записать jti в таблицу отозванных. Вызывается при logout."""
    await _ensure_revoked_table(db)
    await db.execute(
        text("INSERT OR IGNORE INTO revoked_tokens (jti, expires_at) VALUES (:jti, :exp)"),
        {"jti": jti, "exp": expires_at.isoformat()},
    )
    await db.commit()


async def is_token_revoked(db: AsyncSession, jti: str) -> bool:
    """True если токен отозван. Заодно чистит истёкшие записи."""
    await _ensure_revoked_table(db)
    now = datetime.now(timezone.utc).isoformat()
    # Удаляем истёкшие (lazy cleanup — не ждём фоновой задачи)
    await db.execute(text("DELETE FROM revoked_tokens WHERE expires_at < :now"), {"now": now})
    row = (await db.execute(
        text("SELECT 1 FROM revoked_tokens WHERE jti = :jti"),
        {"jti": jti},
    )).fetchone()
    await db.commit()
    return row is not None


async def cleanup_revoked_tokens(db: AsyncSession) -> int:
    """Удаляет все истёкшие записи. Вызывается из фоновой задачи main.py."""
    await _ensure_revoked_table(db)
    now = datetime.now(timezone.utc).isoformat()
    result = await db.execute(
        text("DELETE FROM revoked_tokens WHERE expires_at < :now RETURNING jti"),
        {"now": now},
    )
    deleted = len(result.fetchall())
    await db.commit()
    return deleted


def verify_ed25519_signature(public_key_b64: str, message: bytes, signature_b64: str) -> bool:
    try:
        pub_key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64))
        pub_key.verify(base64.b64decode(signature_b64), message)
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False
