import hashlib

import pytest

from shared.security.network_view import NetworkViewGuard


def _hash(label):
    return hashlib.sha256(label.encode()).hexdigest()


def test_consistent_chain_allows_governance(tmp_path):
    guard = NetworkViewGuard(str(tmp_path / "view.json"))
    first = guard.observe_validated_checkpoint(
        source_node_id="peer-a",
        authority_epoch=10,
        checkpoint_hash=_hash("epoch-10"),
        previous_hash=None,
    )
    second = guard.observe_validated_checkpoint(
        source_node_id="peer-b",
        authority_epoch=11,
        checkpoint_hash=_hash("epoch-11"),
        previous_hash=_hash("epoch-10"),
    )
    assert first.governance_allowed
    assert second.governance_allowed
    assert second.data_plane_allowed


def test_conflicting_same_epoch_freezes_only_control_plane(tmp_path):
    guard = NetworkViewGuard(str(tmp_path / "view.json"))
    guard.observe_validated_checkpoint(
        source_node_id="peer-a",
        authority_epoch=10,
        checkpoint_hash=_hash("view-a"),
        previous_hash=None,
    )
    decision = guard.observe_validated_checkpoint(
        source_node_id="peer-b",
        authority_epoch=10,
        checkpoint_hash=_hash("view-b"),
        previous_hash=None,
    )
    assert not decision.governance_allowed
    assert decision.data_plane_allowed


def test_freeze_survives_restart_and_observation_cannot_clear_it(tmp_path):
    path = tmp_path / "view.json"
    guard = NetworkViewGuard(str(path))
    guard.observe_validated_checkpoint(
        source_node_id="peer-a", authority_epoch=5, checkpoint_hash=_hash("a"), previous_hash=None
    )
    guard.observe_validated_checkpoint(
        source_node_id="peer-b", authority_epoch=5, checkpoint_hash=_hash("b"), previous_hash=None
    )
    restored = NetworkViewGuard(str(path))
    assert not restored.decision().governance_allowed
    still_frozen = restored.observe_validated_checkpoint(
        source_node_id="peer-c",
        authority_epoch=6,
        checkpoint_hash=_hash("c"),
        previous_hash=_hash("a"),
    )
    assert not still_frozen.governance_allowed


def test_only_verified_advancing_recovery_unfreezes(tmp_path):
    guard = NetworkViewGuard(str(tmp_path / "view.json"))
    guard.observe_validated_checkpoint(
        source_node_id="peer-a", authority_epoch=5, checkpoint_hash=_hash("a"), previous_hash=None
    )
    guard.observe_validated_checkpoint(
        source_node_id="peer-b", authority_epoch=5, checkpoint_hash=_hash("b"), previous_hash=None
    )
    with pytest.raises(ValueError, match="quorum verified"):
        guard.apply_recovery_checkpoint(
            authority_epoch=6, checkpoint_hash=_hash("recovery"), quorum_verified=False
        )
    decision = guard.apply_recovery_checkpoint(
        authority_epoch=6, checkpoint_hash=_hash("recovery"), quorum_verified=True
    )
    assert decision.governance_allowed
    assert decision.data_plane_allowed


def test_three_sources_with_large_epoch_gap_freeze(tmp_path):
    guard = NetworkViewGuard(str(tmp_path / "view.json"), max_stale_epoch_gap=2)
    guard.observe_validated_checkpoint(
        source_node_id="peer-a", authority_epoch=10, checkpoint_hash=_hash("10"), previous_hash=None
    )
    guard.observe_validated_checkpoint(
        source_node_id="peer-b", authority_epoch=10, checkpoint_hash=_hash("10"), previous_hash=None
    )
    decision = guard.observe_validated_checkpoint(
        source_node_id="peer-c", authority_epoch=7, checkpoint_hash=_hash("7"), previous_hash=None
    )
    assert not decision.governance_allowed
    assert "stale epoch gap" in decision.frozen_reason
