import pytest

from shared.security.observer_selection import ObserverCandidate, select_challenge_observers


SEED = "42" * 32
CANDIDATES = [
    ObserverCandidate(f"observer-{index:02d}", f"operator-{index // 2}")
    for index in range(12)
]


def _select(candidates=CANDIDATES, seed=SEED):
    return select_challenge_observers(
        subject_node_id="subject-a",
        challenge_type="relay_delivery",
        epoch=8,
        randomness_seed_hex=seed,
        eligible_observers=candidates,
        observer_count=5,
    )


def test_selection_is_deterministic_and_order_independent():
    assert _select() == _select(list(reversed(CANDIDATES)))


def test_subject_cannot_observe_itself():
    candidates = CANDIDATES + [ObserverCandidate("subject-a", "operator-subject")]
    assert "subject-a" not in _select(candidates)


def test_selection_prefers_distinct_authority_supplied_groups():
    selected = _select()
    groups = {
        candidate.node_id: candidate.diversity_group for candidate in CANDIDATES
    }
    assert len({groups[node_id] for node_id in selected}) == 5


def test_seed_changes_assignment():
    assert _select(seed="24" * 32) != _select()


def test_conflicting_group_claims_fail_closed():
    with pytest.raises(ValueError, match="conflicting diversity"):
        _select(
            [
                ObserverCandidate("observer-a", "operator-a"),
                ObserverCandidate("observer-a", "operator-b"),
                ObserverCandidate("observer-b", "operator-b"),
                ObserverCandidate("observer-c", "operator-c"),
                ObserverCandidate("observer-d", "operator-d"),
                ObserverCandidate("observer-e", "operator-e"),
            ]
        )
