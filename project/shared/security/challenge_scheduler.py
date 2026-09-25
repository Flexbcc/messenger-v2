"""Proposal-only deterministic ChallengeAssignment scheduler."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping
import uuid

from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.challenge_assignment import build_challenge_assignment
from shared.security.observer_selection import (
    ObserverCandidate,
    select_challenge_observers,
)
from shared.security.randomness_checkpoint import randomness_checkpoint_hash


def selected_observers_from_checkpoint(
    *,
    checkpoint: Mapping[str, Any],
    subject_node_id: str,
    challenge_type: str,
) -> tuple[str, ...]:
    return select_challenge_observers(
        subject_node_id=subject_node_id,
        challenge_type=challenge_type,
        epoch=checkpoint["challenge_epoch"],
        randomness_seed_hex=checkpoint["randomness_seed"],
        eligible_observers=[
            ObserverCandidate(
                node_id=item["node_id"],
                diversity_group=item["diversity_group"],
            )
            for item in checkpoint["eligible_observers"]
        ],
        observer_count=checkpoint["observer_count"],
    )


def build_challenge_assignment_proposal(
    *,
    checkpoint: Mapping[str, Any],
    authority_state: CapabilityAuthorityState,
    subject_node_id: str,
    challenge_type: str,
    not_before: datetime,
    expires_at: datetime,
    previous_hash: str | None = None,
) -> dict[str, Any]:
    """Build an unsigned proposal; validators remain the only signers.

    The caller must obtain ``checkpoint`` from a validated checkpoint store.
    No validator private key is accepted by this function.
    """
    if checkpoint.get("authority_epoch") != authority_state.epoch:
        raise ValueError("randomness checkpoint authority epoch mismatch")
    if list(checkpoint.get("committee", ())) != list(authority_state.committee):
        raise ValueError("randomness checkpoint committee mismatch")
    if checkpoint.get("threshold") != authority_state.threshold:
        raise ValueError("randomness checkpoint threshold mismatch")
    observers = selected_observers_from_checkpoint(
        checkpoint=checkpoint,
        subject_node_id=subject_node_id,
        challenge_type=challenge_type,
    )
    if (
        not_before.tzinfo is None
        or not_before.utcoffset() is None
        or expires_at.tzinfo is None
        or expires_at.utcoffset() is None
    ):
        raise ValueError("challenge proposal times must be timezone-aware")
    checkpoint_hash = randomness_checkpoint_hash(checkpoint)
    schedule_key = "\x00".join(
        (
            checkpoint_hash,
            subject_node_id,
            challenge_type,
            not_before.astimezone(timezone.utc).isoformat(),
            expires_at.astimezone(timezone.utc).isoformat(),
            previous_hash or "",
        )
    )
    assignment_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"ouo:challenge:{schedule_key}"))
    return build_challenge_assignment(
        subject_node_id=subject_node_id,
        observer_node_ids=observers,
        challenge_type=challenge_type,
        epoch=checkpoint["challenge_epoch"],
        authority_epoch=checkpoint["authority_epoch"],
        randomness_commitment=checkpoint_hash,
        not_before=not_before,
        expires_at=expires_at,
        committee=authority_state.committee,
        threshold=authority_state.threshold,
        previous_hash=previous_hash,
        assignment_id=assignment_id,
    )
