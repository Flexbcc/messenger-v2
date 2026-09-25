"""Budgeted semi-constant cover-cell scheduler for a configured peer link."""

from __future__ import annotations

import asyncio
import os
import secrets
from collections import deque
from typing import Awaitable, Callable


CoverSink = Callable[[bytes], Awaitable[None]]


class CoverScheduler:
    def __init__(
        self,
        *,
        cell_size: int,
        interval_seconds: float,
        jitter_seconds: float,
        max_bytes_per_hour: int,
        sink: CoverSink,
        adaptive: bool = True,
    ) -> None:
        if cell_size < 1 or interval_seconds <= 0 or jitter_seconds < 0:
            raise ValueError("invalid cover scheduler configuration")
        if max_bytes_per_hour < cell_size:
            raise ValueError("cover budget must permit at least one cell")
        self.cell_size = cell_size
        self.interval_seconds = interval_seconds
        self.jitter_seconds = jitter_seconds
        self.max_cells_per_hour = max_bytes_per_hour // cell_size
        self.sink = sink
        self.adaptive = adaptive
        self._task: asyncio.Task | None = None
        self._sent_at: deque[float] = deque()
        self._real_load = 0.0
        self._overloaded = False
        self._sent_total = 0
        self._skipped_budget = 0
        self._skipped_load = 0
        self._last_error: str | None = None

    def set_load(self, *, real_utilization: float, overloaded: bool) -> None:
        if not 0.0 <= real_utilization <= 1.0:
            raise ValueError("real utilization must be between zero and one")
        self._real_load = real_utilization
        self._overloaded = bool(overloaded)

    def start(self) -> asyncio.Task:
        if self._task and not self._task.done():
            raise RuntimeError("cover scheduler already started")
        self._task = asyncio.create_task(self._run())
        return self._task

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
            self._task = None

    async def _run(self) -> None:
        while True:
            now = asyncio.get_running_loop().time()
            while self._sent_at and self._sent_at[0] <= now - 3600:
                self._sent_at.popleft()
            load = self._real_load if self.adaptive else 0.0
            if self._overloaded or load >= 0.95:
                self._skipped_load += 1
            elif len(self._sent_at) >= self.max_cells_per_hour:
                self._skipped_budget += 1
            else:
                try:
                    await self.sink(os.urandom(self.cell_size))
                except Exception as exc:
                    self._last_error = str(exc)
                else:
                    self._sent_at.append(now)
                    self._sent_total += 1
                    self._last_error = None
            jitter = self.jitter_seconds * (
                (secrets.randbelow(2_000_001) / 1_000_000) - 1
            )
            adaptive_delay = self.interval_seconds * (1.0 + 4.0 * load)
            await asyncio.sleep(max(0.05, adaptive_delay + jitter))

    def status(self) -> dict[str, int | float | bool | str | None]:
        return {
            "running": bool(self._task and not self._task.done()),
            "adaptive": self.adaptive,
            "real_utilization": self._real_load,
            "overloaded": self._overloaded,
            "sent_last_hour": len(self._sent_at),
            "max_cells_per_hour": self.max_cells_per_hour,
            "sent_total": self._sent_total,
            "skipped_budget": self._skipped_budget,
            "skipped_load": self._skipped_load,
            "last_error": self._last_error,
        }
