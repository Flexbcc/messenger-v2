"""Persistent bounded replay set for unlinkable per-hop onion tags."""

from __future__ import annotations

import hashlib
import os
import sqlite3
import time
from pathlib import Path


class ReplayTagCapacityError(RuntimeError):
    """The bounded replay window is full of still-valid entries."""


class ReplayTagStore:
    def __init__(self, path: str, *, ttl_seconds: int, max_records: int) -> None:
        if not path or not 60 <= ttl_seconds <= 2_592_000:
            raise ValueError("invalid replay tag TTL")
        if not 100 <= max_records <= 10_000_000:
            raise ValueError("invalid replay tag record limit")
        self.path = path
        self.ttl_seconds = ttl_seconds
        self.max_records = max_records
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS mix_replay_tags (
                       tag_hash BLOB PRIMARY KEY,
                       expires_at INTEGER NOT NULL
                   )"""
            )
            connection.execute(
                """CREATE INDEX IF NOT EXISTS idx_mix_replay_expiry
                   ON mix_replay_tags(expires_at)"""
            )
        os.chmod(path, 0o600)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    @staticmethod
    def _digest(tag: bytes) -> bytes:
        if not isinstance(tag, bytes) or not 16 <= len(tag) <= 64:
            raise ValueError("invalid per-hop replay tag")
        return hashlib.sha256(b"OUO/MIX_REPLAY_TAG/v1\x00" + tag).digest()

    def consume(self, tag: bytes) -> bool:
        digest = self._digest(tag)
        now = int(time.time())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM mix_replay_tags WHERE expires_at < ?", (now,)
            )
            if connection.execute(
                "SELECT 1 FROM mix_replay_tags WHERE tag_hash = ?", (digest,)
            ).fetchone():
                connection.rollback()
                return False
            count = connection.execute(
                "SELECT COUNT(*) FROM mix_replay_tags"
            ).fetchone()[0]
            if count >= self.max_records:
                connection.rollback()
                raise ReplayTagCapacityError(
                    "replay protection capacity exhausted by live tags"
                )
            try:
                connection.execute(
                    "INSERT INTO mix_replay_tags(tag_hash, expires_at) VALUES (?, ?)",
                    (digest, now + self.ttl_seconds),
                )
            except sqlite3.IntegrityError:
                connection.rollback()
                return False
            connection.commit()
            return True

    def release(self, tag: bytes) -> None:
        """Release a reservation only when downstream admission did not occur."""
        digest = self._digest(tag)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM mix_replay_tags WHERE tag_hash = ?", (digest,)
            )
            connection.commit()
