import pytest

from shared.security.peer_selection import (
    PeerSelectionError,
    PeerSelectionPolicy,
    select_peer_set,
)


SECRET = b"local-node-selection-secret-32b!!"


def _candidate(index, *, group=None, sources=("d1", "d2"), validated=True):
    return {
        "node_id": f"relay-{index}",
        "endpoint": f"wss://relay-{index}.example/ws",
        "capabilities": ["relay"],
        "observed_by": list(sources),
        "diversity_group": group or f"operator-{index % 6}",
        "validated": validated,
    }


def test_selection_is_deterministic_disjoint_and_locally_seeded():
    candidates = [_candidate(index) for index in range(20)]
    first = select_peer_set(
        candidates,
        self_node_id="home-a",
        capability="relay",
        epoch=7,
        selection_secret=SECRET,
    )
    second = select_peer_set(
        list(reversed(candidates)),
        self_node_id="home-a",
        capability="relay",
        epoch=7,
        selection_secret=SECRET,
    )
    assert [peer.node_id for peer in first.active] == [
        peer.node_id for peer in second.active
    ]
    assert len(first.guards) == 2
    assert len(first.rotating) == 4
    assert len(first.reserves) == 2
    assert {peer.node_id for peer in first.active}.isdisjoint(
        {peer.node_id for peer in first.reserves}
    )
    assert first.degraded is False


def test_previous_guards_survive_partial_rotation_when_still_eligible():
    candidates = [_candidate(index) for index in range(24)]
    initial = select_peer_set(
        candidates,
        self_node_id="home-a",
        capability="relay",
        epoch=10,
        selection_secret=SECRET,
    )
    rotated = select_peer_set(
        candidates,
        self_node_id="home-a",
        capability="relay",
        epoch=11,
        selection_secret=SECRET,
        previous_guard_ids=[peer.node_id for peer in initial.guards],
    )
    assert [peer.node_id for peer in rotated.guards] == [
        peer.node_id for peer in initial.guards
    ]
    assert {peer.node_id for peer in rotated.active} != {
        peer.node_id for peer in initial.active
    }


def test_single_source_self_and_unvalidated_candidates_are_excluded():
    candidates = [_candidate(index) for index in range(10)]
    candidates += [
        _candidate(20, sources=("d1",)),
        _candidate(21, validated=False),
        {
            **_candidate(22),
            "node_id": "home-a",
        },
    ]
    result = select_peer_set(
        candidates,
        self_node_id="home-a",
        capability="relay",
        epoch=1,
        selection_secret=SECRET,
    )
    selected = {peer.node_id for peer in result.active + result.reserves}
    assert "relay-20" not in selected
    assert "relay-21" not in selected
    assert "home-a" not in selected
    assert result.eligible_count == 10


def test_diversity_cap_degrades_instead_of_filling_from_one_operator():
    policy = PeerSelectionPolicy(
        guard_count=2,
        rotating_count=3,
        reserve_count=1,
        max_active_per_diversity_group=2,
        max_guard_per_diversity_group=1,
    )
    result = select_peer_set(
        [_candidate(index, group="one-operator") for index in range(20)],
        self_node_id="home-a",
        capability="relay",
        epoch=1,
        selection_secret=SECRET,
        policy=policy,
    )
    assert len(result.guards) == 1
    assert len(result.active) == 2
    assert result.degraded is True


def test_conflicting_validated_advertisements_fail_closed():
    first = _candidate(1)
    conflicting = {**first, "endpoint": "wss://other.example/ws"}
    with pytest.raises(PeerSelectionError, match="conflicting validated advertisements"):
        select_peer_set(
            [first, conflicting],
            self_node_id="home-a",
            capability="relay",
            epoch=1,
            selection_secret=SECRET,
        )


def test_short_local_selection_secret_is_rejected():
    with pytest.raises(PeerSelectionError, match="at least 32 bytes"):
        select_peer_set(
            [_candidate(index) for index in range(10)],
            self_node_id="home-a",
            capability="relay",
            epoch=1,
            selection_secret=b"short",
        )
