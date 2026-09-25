"""Deterministic external observer selection for synthetic challenges."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Sequence

from shared.security.trust_evidence import CHALLENGE_TYPES


SELECTION_DOMAIN = b"OUO/CHALLENGE_OBSERVER_SELECTION/v1\x00"


@dataclass(frozen=True)
class ObserverCandidate:
    node_id: str
    diversity_group: str


def select_challenge_observers(
    *,
    subject_node_id: str,
    challenge_type: str,
    epoch: int,
    randomness_seed_hex: str,
    eligible_observers: Sequence[ObserverCandidate],
    observer_count: int,
) -> tuple[str, ...]:
    """Select observers without input from the subject node.

    Diversity groups must be supplied by trusted external state; this function
    doesn't infer operator independence from IP/ASN or self-declared metadata.
    It first selects at most one observer per group, then fills remaining slots.
    """
    if not isinstance(subject_node_id, str) or not subject_node_id:
        raise ValueError("subject_node_id is required")
    if challenge_type not in CHALLENGE_TYPES:
        raise ValueError("unsupported challenge_type")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("epoch must be a non-negative integer")
    if re.fullmatch(r"[0-9a-f]{64}", randomness_seed_hex) is None:
        raise ValueError("randomness seed must be 32-byte lowercase hex")
    if not isinstance(observer_count, int) or isinstance(observer_count, bool):
        raise ValueError("observer_count must be an integer")

    unique: dict[str, ObserverCandidate] = {}
    for candidate in eligible_observers:
        if not isinstance(candidate, ObserverCandidate):
            raise ValueError("eligible observers must be ObserverCandidate values")
        if not candidate.node_id or not candidate.diversity_group:
            raise ValueError("observer node_id and diversity_group are required")
        previous = unique.get(candidate.node_id)
        if previous is not None and previous != candidate:
            raise ValueError("observer has conflicting diversity groups")
        unique[candidate.node_id] = candidate
    candidates = [
        candidate for candidate in unique.values() if candidate.node_id != subject_node_id
    ]
    if not 1 <= observer_count <= len(candidates):
        raise ValueError("observer_count exceeds eligible observer set")

    seed = bytes.fromhex(randomness_seed_hex)
    prefix = b"\x00".join(
        (
            SELECTION_DOMAIN + seed,
            subject_node_id.encode(),
            challenge_type.encode(),
            str(epoch).encode(),
        )
    )
    ranked = sorted(
        candidates,
        key=lambda candidate: (
            hashlib.sha256(prefix + b"\x00" + candidate.node_id.encode()).digest(),
            candidate.node_id,
        ),
    )
    selected = []
    selected_ids = set()
    used_groups = set()
    for candidate in ranked:
        if candidate.diversity_group in used_groups:
            continue
        selected.append(candidate.node_id)
        selected_ids.add(candidate.node_id)
        used_groups.add(candidate.diversity_group)
        if len(selected) == observer_count:
            return tuple(sorted(selected))
    for candidate in ranked:
        if candidate.node_id in selected_ids:
            continue
        selected.append(candidate.node_id)
        if len(selected) == observer_count:
            return tuple(sorted(selected))
    raise RuntimeError("observer selection could not satisfy requested count")
