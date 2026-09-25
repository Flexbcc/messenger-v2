import pytest

from simulator.trust import (
    run_trust_simulation,
    simulate_committee_capture,
    simulate_peer_eclipse,
    simulate_relay_failure,
    simulate_unsigned_sybil_escalation,
)


@pytest.mark.parametrize("node_count", [100, 1_000, 10_000])
def test_unsigned_l0_sybil_population_cannot_gain_relay(node_count):
    result = simulate_unsigned_sybil_escalation(node_count)
    assert result.node_count == node_count
    assert result.accepted_infrastructure_capabilities == 0


def test_committee_capture_is_deterministic_and_bounded():
    first = simulate_committee_capture(
        validator_count=100, compromised_validators=20, trials=500
    )
    second = simulate_committee_capture(
        validator_count=100, compromised_validators=20, trials=500
    )
    assert first == second
    assert 0 <= first.capture_rate <= 1


def test_full_validator_compromise_always_captures_committee():
    result = simulate_committee_capture(
        validator_count=20, compromised_validators=20, trials=100
    )
    assert result.capture_rate == 1


def test_report_states_limited_scope():
    report = run_trust_simulation(
        node_counts=[10], compromised_counts=[0, 10], trials=20
    )
    assert "not a proof" in report["scope"]
    assert report["sybil"][0]["accepted_infrastructure_capabilities"] == 0
    assert len(report["peer_eclipse"]) == 3


def test_ten_thousand_single_source_sybils_are_not_peer_eligible():
    result = simulate_peer_eclipse(
        honest_nodes=100,
        sybil_nodes=10_000,
        trials=10,
        sybil_source_count=1,
        sybil_diversity="spoofed",
    )
    assert result.active_eclipses == 0
    assert result.guard_captures == 0
    assert result.malicious_active_slots == 0


def test_operator_diversity_cap_prevents_one_group_from_filling_active_set():
    result = simulate_peer_eclipse(
        honest_nodes=100,
        sybil_nodes=1_000,
        trials=20,
        sybil_source_count=2,
        sybil_diversity="single-operator",
    )
    assert result.active_eclipses == 0
    assert result.mean_malicious_active_fraction <= 2 / 6


def test_spoofed_diversity_is_explicit_residual_eclipse_risk():
    result = simulate_peer_eclipse(
        honest_nodes=0,
        sybil_nodes=100,
        trials=10,
        sybil_source_count=2,
        sybil_diversity="spoofed",
    )
    assert result.guard_capture_rate == 1
    assert result.active_eclipse_rate == 1


def test_relay_failure_simulation_is_deterministic_and_multipath_improves_delivery():
    single = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=1,
        required_routes=1,
        trials=2_000,
    )
    repeated = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=1,
        required_routes=1,
        trials=2_000,
    )
    multipath = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=3,
        required_routes=1,
        trials=2_000,
    )
    erasure = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=10,
        required_routes=6,
        trials=2_000,
    )
    assert single == repeated
    assert 0.67 <= single.delivery_rate <= 0.73
    assert multipath.delivery_rate > single.delivery_rate
    assert erasure.delivery_rate > single.delivery_rate


def test_multi_hop_availability_cost_is_measured():
    one_hop = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=3,
        required_routes=1,
        trials=1_000,
        hops_per_route=1,
    )
    three_hop = simulate_relay_failure(
        relay_count=100,
        failure_probability=0.30,
        route_count=3,
        required_routes=1,
        trials=1_000,
        hops_per_route=3,
    )
    assert three_hop.delivery_rate < one_hop.delivery_rate
