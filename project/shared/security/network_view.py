"""Control-plane Safe Mode state machine for already-validated checkpoints."""

import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


HASH_RE = re.compile(r"[0-9a-f]{64}")


@dataclass(frozen=True)
class NetworkViewDecision:
    governance_allowed: bool
    data_plane_allowed: bool
    frozen_reason: Optional[str]
    highest_epoch: int
    highest_hash: Optional[str]


class NetworkViewGuard:
    """Consumes checkpoints only after their quorum certificate was verified.

    A freeze is sticky across restart. Ordinary observations can enter Safe
    Mode but cannot clear it; only an explicit verified recovery checkpoint can.
    """

    def __init__(self, path: str, *, max_stale_epoch_gap: int = 2):
        if max_stale_epoch_gap < 0:
            raise ValueError("max_stale_epoch_gap cannot be negative")
        self.path = Path(path)
        self.max_stale_epoch_gap = max_stale_epoch_gap
        self.highest_epoch = -1
        self.highest_hash: Optional[str] = None
        self.frozen_reason: Optional[str] = None
        self.observations: dict[str, tuple[int, str]] = {}
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except (json.JSONDecodeError, OSError) as exc:
            raise ValueError("invalid persisted NetworkView state") from exc
        if not isinstance(data, dict) or set(data) != {
            "highest_epoch",
            "highest_hash",
            "frozen_reason",
        }:
            raise ValueError("invalid persisted NetworkView state")
        epoch = data["highest_epoch"]
        digest = data["highest_hash"]
        reason = data["frozen_reason"]
        if not isinstance(epoch, int) or epoch < -1:
            raise ValueError("invalid persisted NetworkView epoch")
        if digest is not None and (not isinstance(digest, str) or not HASH_RE.fullmatch(digest)):
            raise ValueError("invalid persisted NetworkView hash")
        if reason is not None and not isinstance(reason, str):
            raise ValueError("invalid persisted NetworkView reason")
        self.highest_epoch = epoch
        self.highest_hash = digest
        self.frozen_reason = reason

    def _persist(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary_name: Optional[str] = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=self.path.parent,
                prefix=f".{self.path.name}.",
                delete=False,
            ) as temporary:
                temporary_name = temporary.name
                json.dump(
                    {
                        "highest_epoch": self.highest_epoch,
                        "highest_hash": self.highest_hash,
                        "frozen_reason": self.frozen_reason,
                    },
                    temporary,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                temporary.write("\n")
                temporary.flush()
                os.fsync(temporary.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, self.path)
        finally:
            if temporary_name and os.path.exists(temporary_name):
                os.unlink(temporary_name)

    def decision(self) -> NetworkViewDecision:
        return NetworkViewDecision(
            governance_allowed=self.frozen_reason is None,
            data_plane_allowed=True,
            frozen_reason=self.frozen_reason,
            highest_epoch=self.highest_epoch,
            highest_hash=self.highest_hash,
        )

    def _freeze(self, reason: str) -> NetworkViewDecision:
        if self.frozen_reason is None:
            self.frozen_reason = reason
            self._persist()
        return self.decision()

    def force_freeze(self, reason: str) -> NetworkViewDecision:
        """Freeze after a caller has verified cryptographic evidence."""
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("freeze reason is required")
        return self._freeze(reason.strip())

    def observe_validated_checkpoint(
        self,
        *,
        source_node_id: str,
        authority_epoch: int,
        checkpoint_hash: str,
        previous_hash: Optional[str],
    ) -> NetworkViewDecision:
        if not isinstance(source_node_id, str) or not source_node_id:
            raise ValueError("source_node_id is required")
        if not isinstance(authority_epoch, int) or isinstance(authority_epoch, bool) or authority_epoch < 0:
            raise ValueError("invalid authority_epoch")
        if not isinstance(checkpoint_hash, str) or not HASH_RE.fullmatch(checkpoint_hash):
            raise ValueError("invalid checkpoint_hash")
        if previous_hash is not None and (
            not isinstance(previous_hash, str) or not HASH_RE.fullmatch(previous_hash)
        ):
            raise ValueError("invalid previous_hash")

        self.observations[source_node_id] = (authority_epoch, checkpoint_hash)
        same_epoch_hashes = {
            digest for epoch, digest in self.observations.values() if epoch == authority_epoch
        }
        if len(same_epoch_hashes) > 1:
            return self._freeze("conflicting quorum checkpoints at one authority epoch")

        if len(self.observations) >= 3:
            epochs = [epoch for epoch, _ in self.observations.values()]
            if max(epochs) - min(epochs) > self.max_stale_epoch_gap:
                return self._freeze("network views exceed allowed stale epoch gap")

        if self.highest_epoch >= 0 and authority_epoch == self.highest_epoch + 1:
            if previous_hash != self.highest_hash:
                return self._freeze("authority checkpoint chain is broken")
        elif self.highest_epoch >= 0 and authority_epoch > self.highest_epoch + 1:
            return self._freeze("authority checkpoint chain has an unresolved gap")

        if authority_epoch > self.highest_epoch:
            self.highest_epoch = authority_epoch
            self.highest_hash = checkpoint_hash
            self._persist()
        elif authority_epoch == self.highest_epoch and checkpoint_hash != self.highest_hash:
            return self._freeze("conflicting local checkpoint at highest epoch")
        return self.decision()

    def apply_recovery_checkpoint(
        self,
        *,
        authority_epoch: int,
        checkpoint_hash: str,
        quorum_verified: bool,
    ) -> NetworkViewDecision:
        if not quorum_verified:
            raise ValueError("recovery checkpoint must be quorum verified")
        if not isinstance(authority_epoch, int) or authority_epoch <= self.highest_epoch:
            raise ValueError("recovery checkpoint epoch must advance")
        if not isinstance(checkpoint_hash, str) or not HASH_RE.fullmatch(checkpoint_hash):
            raise ValueError("invalid recovery checkpoint hash")
        self.highest_epoch = authority_epoch
        self.highest_hash = checkpoint_hash
        self.frozen_reason = None
        self.observations.clear()
        self._persist()
        return self.decision()
