"""Common lifecycle and role model for a logical OUO node process."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Mapping, Sequence

from shared.security.node_registration import NodeRegistrationClient


StartHook = Callable[[], Awaitable[None] | asyncio.Task | None]
StopHook = Callable[[], Awaitable[None] | None]
HealthHook = Callable[[], Mapping[str, Any]]


@dataclass(frozen=True)
class NodeRole:
    capability: str
    start: StartHook | None = None
    stop: StopHook | None = None
    health: HealthHook | None = None


class NodeRuntime:
    """Own one Node Identity lifecycle and several certified service roles."""

    def __init__(
        self,
        *,
        registration: NodeRegistrationClient,
        configured_capabilities: Sequence[str],
        roles: Sequence[NodeRole],
    ) -> None:
        configured = tuple(sorted(set(configured_capabilities)))
        role_map = {role.capability: role for role in roles}
        if len(role_map) != len(roles):
            raise ValueError("duplicate NodeRuntime role")
        missing = set(configured) - set(role_map)
        if missing:
            raise ValueError(f"missing runtime role implementations: {sorted(missing)}")
        self.registration = registration
        self.capabilities = configured
        self.roles = role_map
        self._role_tasks: set[asyncio.Task] = set()
        self._started = False

    async def start(self) -> None:
        if self._started:
            raise RuntimeError("NodeRuntime is already started")
        self._started = True
        self.registration.start()
        try:
            for capability in self.capabilities:
                hook = self.roles[capability].start
                if hook is None:
                    continue
                result = hook()
                if isinstance(result, asyncio.Task):
                    self._role_tasks.add(result)
                    result.add_done_callback(self._role_tasks.discard)
                elif result is not None:
                    await result
        except Exception:
            await self.stop()
            raise

    async def stop(self) -> None:
        for task in list(self._role_tasks):
            task.cancel()
        if self._role_tasks:
            await asyncio.gather(*self._role_tasks, return_exceptions=True)
        self._role_tasks.clear()
        for capability in reversed(self.capabilities):
            hook = self.roles[capability].stop
            if hook is not None:
                result = hook()
                if result is not None:
                    await result
        await self.registration.stop()
        self._started = False

    def health(self) -> dict[str, Any]:
        role_health = {}
        for capability in self.capabilities:
            hook = self.roles[capability].health
            role_health[capability] = dict(hook()) if hook is not None else {"status": "ok"}
        return {
            "started": self._started,
            "capabilities": list(self.capabilities),
            "registration": self.registration.status(),
            "roles": role_health,
        }
