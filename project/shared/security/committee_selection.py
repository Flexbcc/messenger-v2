"""Deterministic validator committee selection from trusted external inputs."""

import hashlib
import re
from typing import Sequence


SELECTION_DOMAIN = b"OUO/VALIDATOR_COMMITTEE/v1\x00"


def select_validator_committee(
    *,
    candidate_node_id: str,
    authority_epoch: int,
    randomness_seed_hex: str,
    eligible_validator_ids: Sequence[str],
    committee_size: int,
) -> tuple[str, ...]:
    if not isinstance(authority_epoch, int) or isinstance(authority_epoch, bool) or authority_epoch < 0:
        raise ValueError("authority_epoch must be a non-negative integer")
    if re.fullmatch(r"[0-9a-f]{64}", randomness_seed_hex) is None:
        raise ValueError("randomness seed must be 32-byte lowercase hex")
    if not isinstance(candidate_node_id, str) or not candidate_node_id:
        raise ValueError("candidate_node_id is required")
    if any(not isinstance(node_id, str) or not node_id for node_id in eligible_validator_ids):
        raise ValueError("eligible validator IDs must be non-empty strings")
    eligible = sorted(set(eligible_validator_ids))
    eligible = [node_id for node_id in eligible if node_id != candidate_node_id]
    if not isinstance(committee_size, int) or isinstance(committee_size, bool):
        raise ValueError("committee_size must be an integer")
    if not 1 <= committee_size <= len(eligible):
        raise ValueError("committee_size exceeds eligible validator set")

    seed = bytes.fromhex(randomness_seed_hex)
    prefix = (
        SELECTION_DOMAIN
        + seed
        + authority_epoch.to_bytes(8, "big")
        + candidate_node_id.encode("utf-8")
        + b"\x00"
    )
    ranked = sorted(
        eligible,
        key=lambda validator_id: (
            hashlib.sha256(prefix + validator_id.encode("utf-8")).digest(),
            validator_id,
        ),
    )
    return tuple(sorted(ranked[:committee_size]))
