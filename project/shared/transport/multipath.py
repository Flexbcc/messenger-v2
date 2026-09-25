"""Disjoint route allocation for independently encoded transport shards."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from shared.transport.route_builder import TransportPeer, choose_route


@dataclass(frozen=True)
class ShardRoute:
    shard_index: int
    route: tuple[TransportPeer, ...]


def plan_multipath(
    candidates: Sequence[TransportPeer],
    *,
    shard_count: int,
    hop_count: int,
    max_paths: int = 3,
    excluded_node_ids: Sequence[str] = (),
) -> tuple[ShardRoute, ...]:
    if not 1 <= shard_count <= 64 or not 1 <= max_paths <= 8:
        raise ValueError("invalid multipath bounds")
    paths: list[tuple[TransportPeer, ...]] = []
    used: set[str] = set(excluded_node_ids)
    path_count = min(shard_count, max_paths)
    for _index in range(path_count):
        try:
            route = choose_route(
                candidates, hop_count=hop_count, excluded_node_ids=tuple(used)
            )
        except ValueError:
            # Node-disjoint paths are preferred. If the candidate population is
            # too small, retain route diversity without weakening hop count.
            route = choose_route(
                candidates,
                hop_count=hop_count,
                excluded_node_ids=excluded_node_ids,
            )
        paths.append(route)
        used.update(peer.node_id for peer in route)
    return tuple(
        ShardRoute(shard_index=index, route=paths[index % len(paths)])
        for index in range(shard_count)
    )
