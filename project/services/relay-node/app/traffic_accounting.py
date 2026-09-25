"""Bounded sliding-window accounting for Relay traffic."""

from __future__ import annotations

import json
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Any, Mapping


@dataclass
class _OriginWindow:
    requests: deque[float] = field(default_factory=deque)
    quota: deque[tuple[float, int]] = field(default_factory=deque)


class RelayTrafficAccounting:
    def __init__(self, *, window_seconds: int, request_limit: int, max_origins: int):
        if window_seconds < 1 or request_limit < 1 or max_origins < 1:
            raise ValueError("Relay traffic limits must be positive")
        self._window_seconds = window_seconds
        self._request_limit = request_limit
        self._max_origins = max_origins
        self._origins: OrderedDict[str, _OriginWindow] = OrderedDict()

    @property
    def tracked_origins(self) -> int:
        return len(self._origins)

    def _window(self, origin_node_id: str, *, now: float) -> _OriginWindow | None:
        if (
            not isinstance(origin_node_id, str)
            or not origin_node_id
            or len(origin_node_id) > 256
            or any(character.isspace() for character in origin_node_id)
        ):
            return None
        existing = self._origins.pop(origin_node_id, None)
        if existing is not None:
            self._origins[origin_node_id] = existing
            return existing
        cutoff = now - self._window_seconds
        while len(self._origins) >= self._max_origins:
            oldest_id, oldest = next(iter(self._origins.items()))
            requests_active = bool(oldest.requests and oldest.requests[-1] >= cutoff)
            quota_active = bool(oldest.quota and oldest.quota[-1][0] >= cutoff)
            if requests_active or quota_active:
                # Do not evict live accounting state: doing so would let a
                # caller reset its limit by flooding distinct identities.
                return None
            self._origins.pop(oldest_id)
        created = _OriginWindow()
        self._origins[origin_node_id] = created
        return created

    def allow_request(self, origin_node_id: str, *, now: float) -> bool:
        window = self._window(origin_node_id, now=now)
        if window is None:
            return False
        cutoff = now - self._window_seconds
        while window.requests and window.requests[0] < cutoff:
            window.requests.popleft()
        if len(window.requests) >= self._request_limit:
            return False
        window.requests.append(now)
        return True

    def allow_certified_quota(
        self,
        origin_node_id: str,
        payload: Mapping[str, Any],
        quotas: Mapping[str, Any],
        *,
        now: float,
    ) -> bool:
        cell_limit = quotas.get("max_cells_per_epoch")
        bandwidth_bps = quotas.get("max_bandwidth_bps")
        if cell_limit is None and bandwidth_bps is None:
            return True
        if cell_limit is not None and (
            not isinstance(cell_limit, int)
            or isinstance(cell_limit, bool)
            or not 0 <= cell_limit <= 1_000_000_000
        ):
            return False
        if bandwidth_bps is not None and (
            not isinstance(bandwidth_bps, int)
            or isinstance(bandwidth_bps, bool)
            or not 0 <= bandwidth_bps <= 1_000_000_000_000
        ):
            return False

        window = self._window(origin_node_id, now=now)
        if window is None:
            return False
        cutoff = now - self._window_seconds
        while window.quota and window.quota[0][0] < cutoff:
            window.quota.popleft()
        encoded_bytes = len(
            json.dumps(
                payload, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
        )
        if cell_limit is not None and (
            cell_limit == 0 or len(window.quota) >= cell_limit
        ):
            return False
        if bandwidth_bps is not None:
            byte_budget = bandwidth_bps * self._window_seconds // 8
            if byte_budget <= 0 or (
                sum(entry[1] for entry in window.quota) + encoded_bytes
                > byte_budget
            ):
                return False
        window.quota.append((now, encoded_bytes))
        return True
