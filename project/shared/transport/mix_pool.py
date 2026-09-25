"""Bounded in-memory Mix Pool with expiry, jitter and cover-first eviction."""

from __future__ import annotations

import asyncio
import heapq
import secrets
from dataclasses import dataclass, field
from time import monotonic
from typing import Awaitable, Callable


Forwarder = Callable[[bytes], Awaitable[None]]


@dataclass(order=True)
class _ScheduledCell:
    release_at: float
    order: int
    expires_at: float = field(compare=False)
    payload: bytes = field(compare=False)
    is_cover: bool = field(compare=False)


class MixPoolFull(RuntimeError):
    pass


class MixPool:
    def __init__(
        self,
        *,
        max_cells: int,
        max_bytes: int,
        min_delay_seconds: float,
        max_delay_seconds: float,
    ) -> None:
        if max_cells < 1 or max_bytes < 1:
            raise ValueError("Mix Pool limits must be positive")
        if min_delay_seconds < 0 or max_delay_seconds < min_delay_seconds:
            raise ValueError("invalid Mix Pool delay range")
        self.max_cells = max_cells
        self.max_bytes = max_bytes
        self.min_delay_seconds = min_delay_seconds
        self.max_delay_seconds = max_delay_seconds
        self._cells: list[_ScheduledCell] = []
        self._bytes = 0
        self._inflight_cells = 0
        self._inflight_bytes = 0
        self._order = 0
        self._lock = asyncio.Lock()

    def _delay(self) -> float:
        span = self.max_delay_seconds - self.min_delay_seconds
        return self.min_delay_seconds + span * (secrets.randbelow(1_000_001) / 1_000_000)

    def _remove_index(self, index: int) -> None:
        cell = self._cells[index]
        self._bytes -= len(cell.payload)
        self._cells[index] = self._cells[-1]
        self._cells.pop()
        if self._cells:
            heapq.heapify(self._cells)

    def _purge_expired(self, now: float) -> None:
        retained = [cell for cell in self._cells if cell.expires_at > now]
        self._cells = retained
        heapq.heapify(self._cells)
        self._bytes = sum(len(cell.payload) for cell in retained)

    def _evict_cover(self, required_bytes: int) -> None:
        while (
            len(self._cells) + self._inflight_cells >= self.max_cells
            or self._bytes + self._inflight_bytes + required_bytes > self.max_bytes
        ):
            cover_indexes = [
                index for index, cell in enumerate(self._cells) if cell.is_cover
            ]
            if not cover_indexes:
                return
            self._remove_index(max(cover_indexes, key=lambda i: self._cells[i].release_at))

    async def enqueue(
        self,
        payload: bytes,
        *,
        lifetime_seconds: float,
        is_cover: bool = False,
    ) -> None:
        if not payload or len(payload) > self.max_bytes:
            raise ValueError("invalid Mix Pool cell size")
        if lifetime_seconds <= 0:
            raise ValueError("cell lifetime must be positive")
        async with self._lock:
            now = monotonic()
            self._purge_expired(now)
            if not is_cover:
                self._evict_cover(len(payload))
            if (
                len(self._cells) + self._inflight_cells >= self.max_cells
                or self._bytes + self._inflight_bytes + len(payload) > self.max_bytes
            ):
                raise MixPoolFull("Mix Pool resource budget exhausted")
            self._order += 1
            heapq.heappush(
                self._cells,
                _ScheduledCell(
                    release_at=now + self._delay(),
                    order=self._order,
                    expires_at=now + lifetime_seconds,
                    payload=payload,
                    is_cover=is_cover,
                ),
            )
            self._bytes += len(payload)

    async def drain_ready(self, forward: Forwarder, *, batch_limit: int) -> int:
        if batch_limit < 1:
            raise ValueError("batch_limit must be positive")
        async with self._lock:
            now = monotonic()
            self._purge_expired(now)
            ready: list[_ScheduledCell] = []
            while self._cells and self._cells[0].release_at <= now and len(ready) < batch_limit:
                cell = heapq.heappop(self._cells)
                self._bytes -= len(cell.payload)
                self._inflight_cells += 1
                self._inflight_bytes += len(cell.payload)
                ready.append(cell)
        # Randomize equal-window cells outside the lock and never hold memory
        # admission while the downstream transport is slow.
        secrets.SystemRandom().shuffle(ready)
        for index, cell in enumerate(ready):
            try:
                await forward(cell.payload)
            except (Exception, asyncio.CancelledError):
                retry_at = monotonic() + max(0.05, self.min_delay_seconds)
                async with self._lock:
                    now = monotonic()
                    for pending in ready[index:]:
                        self._inflight_cells -= 1
                        self._inflight_bytes -= len(pending.payload)
                        if pending.expires_at <= now:
                            continue
                        restored = _ScheduledCell(
                            release_at=retry_at,
                            order=pending.order,
                            expires_at=pending.expires_at,
                            payload=pending.payload,
                            is_cover=pending.is_cover,
                        )
                        heapq.heappush(self._cells, restored)
                        self._bytes += len(restored.payload)
                raise
            else:
                async with self._lock:
                    self._inflight_cells -= 1
                    self._inflight_bytes -= len(cell.payload)
        return len(ready)

    async def health(self) -> dict[str, int]:
        async with self._lock:
            self._purge_expired(monotonic())
            return {
                "cells": len(self._cells),
                "bytes": self._bytes,
                "inflight_cells": self._inflight_cells,
                "inflight_bytes": self._inflight_bytes,
                "max_cells": self.max_cells,
                "max_bytes": self.max_bytes,
                "cover_cells": sum(1 for cell in self._cells if cell.is_cover),
            }
