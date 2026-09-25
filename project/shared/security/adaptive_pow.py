"""Bounded adaptive Hashcash gate for anonymous admission only."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class PowChallenge:
    challenge: str
    difficulty: int
    expires_in_seconds: int
    algorithm: str = "sha256-leading-zero-bits"


class AdaptivePowGate:
    def __init__(self, *, ttl_seconds: int = 120, max_challenges: int = 10_000) -> None:
        if not 10 <= ttl_seconds <= 600 or not 1 <= max_challenges <= 1_000_000:
            raise ValueError("invalid adaptive PoW bounds")
        self.ttl_seconds = ttl_seconds
        self.max_challenges = max_challenges
        self.difficulty = 0
        self._challenges: dict[str, tuple[float, int]] = {}

    def set_difficulty(self, bits: int) -> None:
        if not 0 <= bits <= 24:
            raise ValueError("PoW difficulty must be between 0 and 24 bits")
        self.difficulty = bits

    def issue(self) -> PowChallenge:
        self._purge()
        if len(self._challenges) >= self.max_challenges:
            raise RuntimeError("anonymous PoW challenge budget exhausted")
        challenge = secrets.token_urlsafe(24)
        self._challenges[challenge] = (time.monotonic() + self.ttl_seconds, self.difficulty)
        return PowChallenge(challenge, self.difficulty, self.ttl_seconds)

    def verify(self, challenge: str, nonce: str) -> bool:
        record = self._challenges.pop(challenge, None)
        if record is None:
            return False
        expires_at, difficulty = record
        if time.monotonic() > expires_at:
            return False
        digest = hashlib.sha256(f"{challenge}:{nonce}".encode()).digest()
        whole, remaining = divmod(difficulty, 8)
        expected = b"\x00" * whole
        if not hmac.compare_digest(digest[:whole], expected):
            return False
        return remaining == 0 or digest[whole] >> (8 - remaining) == 0

    def _purge(self) -> None:
        now = time.monotonic()
        self._challenges = {
            key: value for key, value in self._challenges.items() if value[0] > now
        }
