"""OUO policy checks applied after standard TUF target verification."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Mapping


POLICY_VERSION = "ouo-update-policy/1"
STATE_VERSION = "ouo-update-state/1"
REQUIRED_CUSTOM_FIELDS = {
    "policy_version",
    "release_version",
    "release_epoch",
    "protocol_version",
    "minimum_protocol_version",
    "rollout_percent",
}


@dataclass(frozen=True)
class UpdateDecision:
    target_path: str
    release_version: str
    release_epoch: int
    protocol_version: int
    eligible: bool


def validate_target_path(value: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError("invalid update target path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or len(value.encode()) > 512:
        raise ValueError("unsafe update target path")
    return value


def evaluate_update(
    *,
    target_path: str,
    custom: Mapping[str, Any] | None,
    node_id: str,
    current_protocol_version: int,
    state: Mapping[str, Any] | None,
) -> UpdateDecision:
    target_path = validate_target_path(target_path)
    if (
        not isinstance(node_id, str)
        or not node_id.startswith("ouo-node-v1-")
        or len(node_id) != 64
        or any(character not in "abcdefghijklmnopqrstuvwxyz234567" for character in node_id[12:])
    ):
        raise ValueError("invalid self-certifying NodeID")
    if (
        not isinstance(current_protocol_version, int)
        or isinstance(current_protocol_version, bool)
        or current_protocol_version < 1
    ):
        raise ValueError("invalid current protocol version")
    if not isinstance(custom, Mapping) or set(custom) != REQUIRED_CUSTOM_FIELDS:
        raise ValueError("invalid critical OUO target metadata")
    if custom.get("policy_version") != POLICY_VERSION:
        raise ValueError("unsupported critical update policy")
    release_version = custom.get("release_version")
    release_epoch = custom.get("release_epoch")
    protocol_version = custom.get("protocol_version")
    minimum_protocol = custom.get("minimum_protocol_version")
    rollout_percent = custom.get("rollout_percent")
    if not isinstance(release_version, str) or not 1 <= len(release_version) <= 64:
        raise ValueError("invalid release version")
    for value, label in (
        (release_epoch, "release epoch"),
        (protocol_version, "protocol version"),
        (minimum_protocol, "minimum protocol version"),
        (rollout_percent, "rollout percent"),
    ):
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError(f"invalid {label}")
    if release_epoch < 1 or protocol_version < 1 or minimum_protocol < 1:
        raise ValueError("invalid update version bounds")
    if not 1 <= rollout_percent <= 100:
        raise ValueError("invalid rollout percent")
    if current_protocol_version < minimum_protocol:
        raise ValueError("node protocol is below release migration floor")
    if protocol_version < current_protocol_version:
        raise ValueError("protocol downgrade detected")
    if state is not None:
        _validate_state(state)
        if release_epoch <= state["highest_release_epoch"]:
            raise ValueError("release rollback detected")

    bucket = int.from_bytes(
        hashlib.sha256(
            b"OUO/UPDATE_ROLLOUT/v1\x00"
            + node_id.encode("utf-8")
            + b"\x00"
            + str(release_epoch).encode("ascii")
        ).digest()[:8],
        "big",
    ) % 100
    return UpdateDecision(
        target_path=target_path,
        release_version=release_version,
        release_epoch=release_epoch,
        protocol_version=protocol_version,
        eligible=bucket < rollout_percent,
    )


def load_state(path: str) -> dict[str, Any] | None:
    target = Path(path)
    if not target.exists():
        return None
    if target.is_symlink() or not target.is_file():
        raise PermissionError("update state must be a regular file")
    value = json.loads(target.read_text(encoding="utf-8"))
    _validate_state(value)
    return value


def commit_state(path: str, decision: UpdateDecision) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    current = load_state(path)
    if current is not None and decision.release_epoch <= current["highest_release_epoch"]:
        raise ValueError("release state rollback")
    value = {
        "state_version": STATE_VERSION,
        "highest_release_epoch": decision.release_epoch,
        "release_version": decision.release_version,
        "protocol_version": decision.protocol_version,
    }
    descriptor, temporary = tempfile.mkstemp(prefix=".update-state-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _validate_state(value: Any) -> None:
    if (
        not isinstance(value, dict)
        or set(value) != {
            "state_version",
            "highest_release_epoch",
            "release_version",
            "protocol_version",
        }
        or value.get("state_version") != STATE_VERSION
        or not isinstance(value.get("highest_release_epoch"), int)
        or isinstance(value.get("highest_release_epoch"), bool)
        or value["highest_release_epoch"] < 1
        or not isinstance(value.get("release_version"), str)
        or not isinstance(value.get("protocol_version"), int)
        or isinstance(value.get("protocol_version"), bool)
    ):
        raise ValueError("invalid update high-watermark state")
