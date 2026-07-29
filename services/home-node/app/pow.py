"""Proof-of-Work для регистрации (Task #69 — Anti-spam PoW).

Hashcash-style: клиент ищет nonce такой что
  sha256(challenge + ":" + nonce).hex() начинается с `difficulty` нулей.

Difficulty задаётся через env REGISTRATION_POW_DIFFICULTY (по умолчанию 4).
0 = PoW отключён (для тестов/dev).

Challenges хранятся в памяти с TTL (не в БД — они одноразовые и короткоживущие).
"""
from __future__ import annotations

import hashlib
import os
import secrets
import time
from typing import Optional

_DIFFICULTY: int = int(os.environ.get("REGISTRATION_POW_DIFFICULTY", "4"))
_CHALLENGE_TTL: int = int(os.environ.get("POW_CHALLENGE_TTL_SECONDS", "300"))  # 5 минут

# In-memory store: challenge → expires_at (monotonic seconds)
_challenges: dict[str, float] = {}

# Cleanup every N verifications (lazy)
_cleanup_counter = 0
_CLEANUP_EVERY = 100


def pow_enabled() -> bool:
    return _DIFFICULTY > 0


def issue_challenge() -> dict:
    """Выдать новый PoW challenge."""
    _lazy_cleanup()
    challenge = secrets.token_hex(16)
    expires_at = time.monotonic() + _CHALLENGE_TTL
    _challenges[challenge] = expires_at
    return {
        "challenge": challenge,
        "difficulty": _DIFFICULTY,
        "ttl_seconds": _CHALLENGE_TTL,
        "algorithm": "sha256-leading-zeros",
    }


def verify_pow(challenge: str, nonce: str) -> Optional[str]:
    """Верифицировать PoW. Возвращает None если OK, иначе описание ошибки.

    Challenge потребляется (одноразовый) — повторное использование отклоняется.
    """
    global _cleanup_counter
    _cleanup_counter += 1
    if _cleanup_counter >= _CLEANUP_EVERY:
        _lazy_cleanup()
        _cleanup_counter = 0

    if not pow_enabled():
        return None  # PoW отключён

    expires_at = _challenges.pop(challenge, None)
    if expires_at is None:
        return "Unknown or already used challenge"
    if time.monotonic() > expires_at:
        return "Challenge expired"

    # Проверяем что sha256(challenge:nonce) начинается с `difficulty` нулей
    digest = hashlib.sha256(f"{challenge}:{nonce}".encode()).hexdigest()
    prefix = "0" * _DIFFICULTY
    if not digest.startswith(prefix):
        return f"Invalid PoW solution: expected {_DIFFICULTY} leading zeros, got {digest[:_DIFFICULTY+4]!r}"

    return None  # OK


def _lazy_cleanup() -> None:
    now = time.monotonic()
    expired = [k for k, exp in _challenges.items() if now > exp]
    for k in expired:
        del _challenges[k]
