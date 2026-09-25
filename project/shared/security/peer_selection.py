"""Deterministic, locally seeded guard/rotating/reserve peer selection."""

from __future__ import annotations

import hashlib
import hmac
from dataclasses import dataclass
from typing import Any, Mapping, Sequence
from urllib.parse import urlsplit


SELECTION_DOMAIN = b"OUO/PEER_SELECTION/v1\x00"


class PeerSelectionError(ValueError):
    pass


@dataclass(frozen=True)
class PeerCandidate:
    node_id: str
    endpoint: str
    capabilities: tuple[str, ...]
    observed_by: tuple[str, ...]
    diversity_group: str


@dataclass(frozen=True)
class PeerSelectionPolicy:
    guard_count: int = 2
    rotating_count: int = 4
    reserve_count: int = 2
    minimum_sources: int = 2
    max_active_per_diversity_group: int = 2
    max_guard_per_diversity_group: int = 1

    def validate(self) -> None:
        if not 1 <= self.guard_count <= 5:
            raise PeerSelectionError("guard_count must be between 1 and 5")
        if not 0 <= self.rotating_count <= 14:
            raise PeerSelectionError("rotating_count must be between 0 and 14")
        if not 5 <= self.guard_count + self.rotating_count <= 15:
            raise PeerSelectionError("active peer target must be between 5 and 15")
        if not 0 <= self.reserve_count <= 15:
            raise PeerSelectionError("reserve_count must be between 0 and 15")
        if not 2 <= self.minimum_sources <= 16:
            raise PeerSelectionError("minimum_sources must be between 2 and 16")
        if not 1 <= self.max_guard_per_diversity_group <= self.guard_count:
            raise PeerSelectionError("invalid guard diversity limit")
        if not 1 <= self.max_active_per_diversity_group <= 15:
            raise PeerSelectionError("invalid active diversity limit")


@dataclass(frozen=True)
class PeerSelectionResult:
    epoch: int
    guards: tuple[PeerCandidate, ...]
    rotating: tuple[PeerCandidate, ...]
    reserves: tuple[PeerCandidate, ...]
    eligible_count: int
    degraded: bool

    @property
    def active(self) -> tuple[PeerCandidate, ...]:
        return self.guards + self.rotating


def _valid_endpoint(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > 2048:
        return False
    parsed = urlsplit(value)
    return bool(
        parsed.scheme in {"https", "wss"}
        and parsed.hostname
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def _normalize_candidate(
    raw: Mapping[str, Any], *, self_node_id: str, capability: str, minimum_sources: int
) -> PeerCandidate | None:
    if not isinstance(raw, Mapping) or raw.get("validated") is not True:
        return None
    node_id = raw.get("node_id")
    endpoint = raw.get("endpoint")
    capabilities = raw.get("capabilities")
    observed_by = raw.get("observed_by")
    if (
        not isinstance(node_id, str)
        or not node_id
        or len(node_id) > 128
        or node_id == self_node_id
        or not _valid_endpoint(endpoint)
        or not isinstance(capabilities, (list, tuple))
        or capability not in capabilities
        or not isinstance(observed_by, (list, tuple))
    ):
        return None
    normalized_capabilities = tuple(sorted(set(capabilities)))
    normalized_sources = tuple(
        sorted(
            {
                source
                for source in observed_by
                if isinstance(source, str) and source and len(source) <= 128
            }
        )
    )
    if len(normalized_sources) < minimum_sources:
        return None
    group = raw.get("diversity_group")
    if not isinstance(group, str) or not group or len(group) > 128:
        group = "unknown"
    return PeerCandidate(
        node_id=node_id,
        endpoint=endpoint,
        capabilities=normalized_capabilities,
        observed_by=normalized_sources,
        diversity_group=group,
    )


def _rank(
    candidates: Sequence[PeerCandidate], *, selection_secret: bytes, epoch: int, bucket: str
) -> list[PeerCandidate]:
    def score(candidate: PeerCandidate) -> bytes:
        payload = (
            SELECTION_DOMAIN
            + str(epoch).encode("ascii")
            + b"\x00"
            + bucket.encode("ascii")
            + b"\x00"
            + candidate.node_id.encode("utf-8")
        )
        return hmac.new(selection_secret, payload, hashlib.sha256).digest()

    return sorted(candidates, key=lambda candidate: (score(candidate), candidate.node_id))


def _take_with_diversity(
    ranked: Sequence[PeerCandidate],
    *,
    count: int,
    group_counts: dict[str, int],
    max_per_group: int,
) -> list[PeerCandidate]:
    selected: list[PeerCandidate] = []
    for candidate in ranked:
        if len(selected) >= count:
            break
        group = candidate.diversity_group
        if group_counts.get(group, 0) >= max_per_group:
            continue
        selected.append(candidate)
        group_counts[group] = group_counts.get(group, 0) + 1
    return selected


def select_peer_set(
    candidates: Sequence[Mapping[str, Any]],
    *,
    self_node_id: str,
    capability: str,
    epoch: int,
    selection_secret: bytes,
    previous_guard_ids: Sequence[str] = (),
    policy: PeerSelectionPolicy = PeerSelectionPolicy(),
) -> PeerSelectionResult:
    policy.validate()
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise PeerSelectionError("epoch must be a non-negative integer")
    if not isinstance(selection_secret, bytes) or len(selection_secret) < 32:
        raise PeerSelectionError("selection_secret must contain at least 32 bytes")
    if not isinstance(self_node_id, str) or not self_node_id:
        raise PeerSelectionError("self_node_id is required")
    if not isinstance(capability, str) or not capability:
        raise PeerSelectionError("capability is required")

    by_node: dict[str, PeerCandidate] = {}
    for raw in candidates:
        candidate = _normalize_candidate(
            raw,
            self_node_id=self_node_id,
            capability=capability,
            minimum_sources=policy.minimum_sources,
        )
        if candidate is None:
            continue
        previous = by_node.get(candidate.node_id)
        if previous is not None and previous != candidate:
            raise PeerSelectionError(
                f"conflicting validated advertisements for node {candidate.node_id}"
            )
        by_node[candidate.node_id] = candidate

    eligible = list(by_node.values())
    guard_group_counts: dict[str, int] = {}
    guards: list[PeerCandidate] = []
    seen_previous: set[str] = set()
    for node_id in previous_guard_ids:
        if node_id in seen_previous:
            continue
        seen_previous.add(node_id)
        candidate = by_node.get(node_id)
        if candidate is None:
            continue
        group = candidate.diversity_group
        if guard_group_counts.get(group, 0) >= policy.max_guard_per_diversity_group:
            continue
        guards.append(candidate)
        guard_group_counts[group] = guard_group_counts.get(group, 0) + 1
        if len(guards) >= policy.guard_count:
            break

    guard_ids = {candidate.node_id for candidate in guards}
    guard_pool = [candidate for candidate in eligible if candidate.node_id not in guard_ids]
    guards.extend(
        _take_with_diversity(
            _rank(
                guard_pool,
                selection_secret=selection_secret,
                epoch=epoch,
                bucket="guards",
            ),
            count=policy.guard_count - len(guards),
            group_counts=guard_group_counts,
            max_per_group=policy.max_guard_per_diversity_group,
        )
    )

    active_group_counts: dict[str, int] = {}
    for candidate in guards:
        active_group_counts[candidate.diversity_group] = (
            active_group_counts.get(candidate.diversity_group, 0) + 1
        )
    guard_ids = {candidate.node_id for candidate in guards}
    rotating_pool = [candidate for candidate in eligible if candidate.node_id not in guard_ids]
    rotating = _take_with_diversity(
        _rank(
            rotating_pool,
            selection_secret=selection_secret,
            epoch=epoch,
            bucket="rotating",
        ),
        count=policy.rotating_count,
        group_counts=active_group_counts,
        max_per_group=policy.max_active_per_diversity_group,
    )

    used_ids = guard_ids | {candidate.node_id for candidate in rotating}
    reserve_pool = [candidate for candidate in eligible if candidate.node_id not in used_ids]
    reserves = _take_with_diversity(
        _rank(
            reserve_pool,
            selection_secret=selection_secret,
            epoch=epoch,
            bucket="reserves",
        ),
        count=policy.reserve_count,
        group_counts={},
        max_per_group=policy.max_active_per_diversity_group,
    )

    degraded = (
        len(guards) < policy.guard_count
        or len(rotating) < policy.rotating_count
        or len(reserves) < policy.reserve_count
    )
    return PeerSelectionResult(
        epoch=epoch,
        guards=tuple(guards),
        rotating=tuple(rotating),
        reserves=tuple(reserves),
        eligible_count=len(eligible),
        degraded=degraded,
    )
