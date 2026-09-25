"""Runtime wrapper for privacy-minimized externally observed node challenges."""

from __future__ import annotations

import hashlib
import inspect
import secrets
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable

from nacl.signing import SigningKey

from shared.security.trust_evidence import CHALLENGE_TYPES, issue_reliability_observation


COMMITMENT_DOMAIN = b"OUO/SYNTHETIC_CHALLENGE/v1\x00"


@dataclass(frozen=True)
class ChallengeContext:
    challenge_id: str
    secret: bytes
    challenge_commitment: str


@dataclass(frozen=True)
class ChallengeExecution:
    observation: dict
    local_detail: str | None = None


def challenge_commitment(
    *,
    challenge_id: str,
    secret: bytes,
    observer_node_id: str,
    subject_node_id: str,
    challenge_type: str,
    epoch: int,
) -> str:
    if not isinstance(secret, bytes) or len(secret) != 32:
        raise ValueError("challenge secret must be 32 bytes")
    encoded = b"\x00".join(
        (
            challenge_id.encode(),
            observer_node_id.encode(),
            subject_node_id.encode(),
            challenge_type.encode(),
            str(epoch).encode(),
        )
    )
    return hashlib.sha256(COMMITMENT_DOMAIN + secret + encoded).hexdigest()


def latency_bucket(latency_ms: float) -> str:
    if latency_ms < 0:
        raise ValueError("latency cannot be negative")
    if latency_ms < 20:
        return "lt_20ms"
    if latency_ms < 50:
        return "20_50ms"
    if latency_ms < 100:
        return "50_100ms"
    if latency_ms < 250:
        return "100_250ms"
    if latency_ms < 1000:
        return "250_1000ms"
    return "gte_1000ms"


async def run_synthetic_challenge(
    *,
    observer_node_id: str,
    subject_node_id: str,
    epoch: int,
    challenge_type: str,
    observer_signing_key: SigningKey,
    action: Callable[[ChallengeContext], bool | Awaitable[bool]],
    evidence_lifetime: timedelta = timedelta(hours=1),
) -> ChallengeExecution:
    """Execute one externally observed action and sign only minimized evidence.

    The secret and any exception detail remain local. The published observation
    contains no user, conversation, mailbox or route identifier.
    """
    if challenge_type not in CHALLENGE_TYPES:
        raise ValueError("unsupported challenge_type")
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("epoch must be a non-negative integer")
    if evidence_lifetime <= timedelta(0) or evidence_lifetime > timedelta(hours=24):
        raise ValueError("evidence_lifetime must be within 24 hours")

    challenge_id = str(uuid.uuid4())
    secret = secrets.token_bytes(32)
    commitment = challenge_commitment(
        challenge_id=challenge_id,
        secret=secret,
        observer_node_id=observer_node_id,
        subject_node_id=subject_node_id,
        challenge_type=challenge_type,
        epoch=epoch,
    )
    context = ChallengeContext(challenge_id, secret, commitment)
    started_wall = datetime.now(timezone.utc)
    started_mono = time.monotonic()
    detail = None
    try:
        outcome = action(context)
        if inspect.isawaitable(outcome):
            outcome = await outcome
        success = outcome is True
        if outcome is not True and outcome is not False:
            detail = "challenge action returned a non-boolean result"
    except Exception as exc:
        success = False
        detail = f"{type(exc).__name__}: {str(exc)[:160]}"
    elapsed_ms = max(0.0, (time.monotonic() - started_mono) * 1000.0)
    observed_at = datetime.now(timezone.utc)
    observation = issue_reliability_observation(
        observer_node_id=observer_node_id,
        subject_node_id=subject_node_id,
        epoch=epoch,
        challenge_type=challenge_type,
        challenge_commitment=commitment,
        result="success" if success else "failure",
        latency_bucket=latency_bucket(elapsed_ms),
        observed_at=observed_at,
        expires_at=max(started_wall, observed_at) + evidence_lifetime,
        observer_signing_key=observer_signing_key,
    )
    return ChallengeExecution(observation=observation, local_detail=detail)
