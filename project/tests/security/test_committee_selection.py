import pytest

from shared.security.committee_selection import select_validator_committee


SEED = "42" * 32
ELIGIBLE = [f"validator-{index:02d}" for index in range(12)]


def test_committee_selection_is_deterministic_and_order_independent():
    first = select_validator_committee(
        candidate_node_id="candidate-a",
        authority_epoch=12,
        randomness_seed_hex=SEED,
        eligible_validator_ids=ELIGIBLE,
        committee_size=7,
    )
    second = select_validator_committee(
        candidate_node_id="candidate-a",
        authority_epoch=12,
        randomness_seed_hex=SEED,
        eligible_validator_ids=list(reversed(ELIGIBLE)),
        committee_size=7,
    )
    assert first == second
    assert len(first) == 7


def test_candidate_cannot_be_its_own_validator():
    committee = select_validator_committee(
        candidate_node_id="validator-00",
        authority_epoch=12,
        randomness_seed_hex=SEED,
        eligible_validator_ids=ELIGIBLE,
        committee_size=7,
    )
    assert "validator-00" not in committee


def test_seed_and_epoch_change_committee_assignment():
    baseline = select_validator_committee(
        candidate_node_id="candidate-a",
        authority_epoch=12,
        randomness_seed_hex=SEED,
        eligible_validator_ids=ELIGIBLE,
        committee_size=7,
    )
    changed = select_validator_committee(
        candidate_node_id="candidate-a",
        authority_epoch=13,
        randomness_seed_hex="24" * 32,
        eligible_validator_ids=ELIGIBLE,
        committee_size=7,
    )
    assert baseline != changed


def test_invalid_external_randomness_is_rejected():
    with pytest.raises(ValueError, match="randomness seed"):
        select_validator_committee(
            candidate_node_id="candidate-a",
            authority_epoch=12,
            randomness_seed_hex="predictable",
            eligible_validator_ids=ELIGIBLE,
            committee_size=7,
        )
