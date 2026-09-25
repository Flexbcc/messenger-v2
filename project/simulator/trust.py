"""Trust/Sybil simulation using the production committee and certificate rules."""

from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable

from shared.security.capability_certificate import (
    build_capability_certificate,
    validate_capability_certificate,
)
from shared.security.committee_selection import select_validator_committee
from shared.security.node_identity import node_id_from_root_public_key
from shared.security.peer_selection import select_peer_set


@dataclass(frozen=True)
class SybilResult:
    node_count: int
    accepted_infrastructure_capabilities: int


@dataclass(frozen=True)
class CommitteeCaptureResult:
    validator_count: int
    compromised_validators: int
    committee_size: int
    threshold: int
    trials: int
    captures: int

    @property
    def capture_rate(self) -> float:
        return self.captures / self.trials if self.trials else 0.0


@dataclass(frozen=True)
class PeerEclipseResult:
    honest_nodes: int
    sybil_nodes: int
    sybil_source_count: int
    sybil_diversity: str
    trials: int
    guard_captures: int
    active_eclipses: int
    degraded_trials: int
    malicious_active_slots: int
    total_active_slots: int

    @property
    def guard_capture_rate(self) -> float:
        return self.guard_captures / self.trials if self.trials else 0.0

    @property
    def active_eclipse_rate(self) -> float:
        return self.active_eclipses / self.trials if self.trials else 0.0

    @property
    def mean_malicious_active_fraction(self) -> float:
        return (
            self.malicious_active_slots / self.total_active_slots
            if self.total_active_slots
            else 0.0
        )


@dataclass(frozen=True)
class RelayFailureResult:
    relay_count: int
    failure_probability: float
    route_count: int
    required_routes: int
    hops_per_route: int
    trials: int
    delivered: int

    @property
    def delivery_rate(self) -> float:
        return self.delivered / self.trials if self.trials else 0.0


def _deterministic_node_id(index: int) -> str:
    material = hashlib.sha256(f"OUO/SIM/SYBIL/{index}".encode()).digest()
    return node_id_from_root_public_key(material)


def simulate_unsigned_sybil_escalation(node_count: int) -> SybilResult:
    """Try to grant Relay capability to unsigned L0 identities.

    This intentionally tests only the structural/quorum invariant. It does not
    claim to model real operator diversity, challenge quality or network abuse.
    """
    if not isinstance(node_count, int) or isinstance(node_count, bool) or node_count < 0:
        raise ValueError("node_count must be a non-negative integer")
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    committee = [f"validator-{index:02d}" for index in range(7)]
    accepted = 0
    for index in range(node_count):
        subject = _deterministic_node_id(index)
        certificate = build_capability_certificate(
            subject_node_id=subject,
            level=0,
            capabilities=["relay"],
            quotas={"max_connections": 1},
            epoch=1,
            issued_at=now - timedelta(minutes=1),
            valid_until=now + timedelta(days=1),
            committee=committee,
            threshold=5,
        )
        validation = validate_capability_certificate(
            certificate,
            now=now,
            expected_committee=committee,
            expected_threshold=5,
            validator_credentials={},
            expected_subject_node_id=subject,
        )
        if validation.valid:
            accepted += 1
    return SybilResult(node_count, accepted)


def simulate_committee_capture(
    *,
    validator_count: int,
    compromised_validators: int,
    trials: int,
    committee_size: int = 7,
    threshold: int = 5,
) -> CommitteeCaptureResult:
    """Measure how often externally-seeded deterministic committees are captured."""
    if not 1 <= committee_size <= validator_count:
        raise ValueError("committee_size must fit validator_count")
    if not 1 <= threshold <= committee_size:
        raise ValueError("threshold must fit committee_size")
    if not 0 <= compromised_validators <= validator_count:
        raise ValueError("compromised_validators must fit validator_count")
    if trials <= 0:
        raise ValueError("trials must be positive")

    validators = [f"validator-{index:05d}" for index in range(validator_count)]
    compromised = set(validators[:compromised_validators])
    captures = 0
    for trial in range(trials):
        seed = hashlib.sha256(f"OUO/SIM/COMMITTEE/{trial}".encode()).hexdigest()
        committee = select_validator_committee(
            candidate_node_id=f"candidate-{trial:08d}",
            authority_epoch=trial // 100 + 1,
            randomness_seed_hex=seed,
            eligible_validator_ids=validators,
            committee_size=committee_size,
        )
        if len(compromised.intersection(committee)) >= threshold:
            captures += 1
    return CommitteeCaptureResult(
        validator_count=validator_count,
        compromised_validators=compromised_validators,
        committee_size=committee_size,
        threshold=threshold,
        trials=trials,
        captures=captures,
    )


def simulate_peer_eclipse(
    *,
    honest_nodes: int,
    sybil_nodes: int,
    trials: int,
    sybil_source_count: int = 2,
    sybil_diversity: str = "single-operator",
) -> PeerEclipseResult:
    """Exercise the production guard selector against a bounded Sybil view.

    This models already parsed candidate records, not compromise probability of
    Discovery or the truth of operator labels. ``spoofed`` explicitly shows the
    residual risk when every Sybil can claim an independent diversity group.
    """
    if honest_nodes < 0 or sybil_nodes < 0 or honest_nodes + sybil_nodes == 0:
        raise ValueError("peer population must be non-empty and non-negative")
    if trials <= 0:
        raise ValueError("trials must be positive")
    if not 0 <= sybil_source_count <= 3:
        raise ValueError("sybil_source_count must be between zero and three")
    if sybil_diversity not in {"single-operator", "spoofed"}:
        raise ValueError("unsupported sybil_diversity")

    candidates = []
    for index in range(honest_nodes):
        candidates.append(
            {
                "node_id": f"honest-{index:06d}",
                "endpoint": f"wss://honest-{index}.example/ws",
                "capabilities": ["relay"],
                "observed_by": ["d1", "d2", "d3"],
                "diversity_group": f"honest-operator-{index % max(1, min(20, honest_nodes))}",
                "validated": True,
            }
        )
    sybil_sources = [f"d{index + 1}" for index in range(sybil_source_count)]
    for index in range(sybil_nodes):
        candidates.append(
            {
                "node_id": f"sybil-{index:06d}",
                "endpoint": f"wss://sybil-{index}.example/ws",
                "capabilities": ["relay"],
                "observed_by": sybil_sources,
                "diversity_group": (
                    "malicious-operator"
                    if sybil_diversity == "single-operator"
                    else f"claimed-operator-{index}"
                ),
                "validated": True,
            }
        )

    guard_captures = active_eclipses = degraded = 0
    malicious_slots = total_slots = 0
    for trial in range(trials):
        secret = hashlib.sha256(f"OUO/SIM/PEER/{trial}".encode()).digest()
        selection = select_peer_set(
            candidates,
            self_node_id="simulator-self",
            capability="relay",
            epoch=trial // 10 + 1,
            selection_secret=secret,
        )
        guards = selection.guards
        active = selection.active
        if guards and all(peer.node_id.startswith("sybil-") for peer in guards):
            guard_captures += 1
        if active and all(peer.node_id.startswith("sybil-") for peer in active):
            active_eclipses += 1
        if selection.degraded:
            degraded += 1
        malicious_slots += sum(peer.node_id.startswith("sybil-") for peer in active)
        total_slots += len(active)
    return PeerEclipseResult(
        honest_nodes=honest_nodes,
        sybil_nodes=sybil_nodes,
        sybil_source_count=sybil_source_count,
        sybil_diversity=sybil_diversity,
        trials=trials,
        guard_captures=guard_captures,
        active_eclipses=active_eclipses,
        degraded_trials=degraded,
        malicious_active_slots=malicious_slots,
        total_active_slots=total_slots,
    )


def simulate_relay_failure(
    *,
    relay_count: int,
    failure_probability: float,
    route_count: int,
    required_routes: int,
    trials: int,
    hops_per_route: int = 1,
) -> RelayFailureResult:
    """Measure delivery when each selected Relay independently fails.

    A route/shard succeeds only when every hop assigned to it is online. The
    container is delivered after ``required_routes`` of ``route_count`` routes
    succeed. Selection and failures are hash-derived for reproducibility.
    This is an availability model, not a traffic-correlation/privacy model.
    """
    if relay_count <= 0:
        raise ValueError("relay_count must be positive")
    if not 0.0 <= failure_probability <= 1.0:
        raise ValueError("failure_probability must be between zero and one")
    if not 1 <= required_routes <= route_count:
        raise ValueError("required_routes must fit route_count")
    if hops_per_route <= 0:
        raise ValueError("hops_per_route must be positive")
    if route_count * hops_per_route > relay_count:
        raise ValueError("relay population is too small for distinct route hops")
    if trials <= 0:
        raise ValueError("trials must be positive")

    threshold = int(failure_probability * (1 << 256))
    delivered = 0
    relay_ids = tuple(range(relay_count))
    for trial in range(trials):
        selected = sorted(
            relay_ids,
            key=lambda relay_id: hashlib.sha256(
                f"OUO/SIM/ROUTE/{trial}/{relay_id}".encode()
            ).digest(),
        )[: route_count * hops_per_route]
        online = {
            relay_id: int.from_bytes(
                hashlib.sha256(
                    f"OUO/SIM/FAIL/{trial}/{relay_id}".encode()
                ).digest(),
                "big",
            )
            >= threshold
            for relay_id in selected
        }
        successful_routes = 0
        for route_index in range(route_count):
            start = route_index * hops_per_route
            route = selected[start : start + hops_per_route]
            if all(online[relay_id] for relay_id in route):
                successful_routes += 1
        if successful_routes >= required_routes:
            delivered += 1
    return RelayFailureResult(
        relay_count=relay_count,
        failure_probability=failure_probability,
        route_count=route_count,
        required_routes=required_routes,
        hops_per_route=hops_per_route,
        trials=trials,
        delivered=delivered,
    )


def run_trust_simulation(
    *,
    node_counts: Iterable[int] = (100, 1_000, 10_000),
    validator_count: int = 100,
    compromised_counts: Iterable[int] = (1, 5, 10, 20, 34),
    trials: int = 2_000,
) -> dict:
    sybil = [simulate_unsigned_sybil_escalation(count) for count in node_counts]
    capture = [
        simulate_committee_capture(
            validator_count=validator_count,
            compromised_validators=count,
            trials=trials,
        )
        for count in compromised_counts
    ]
    eclipse_trials = min(trials, 100)
    eclipse = [
        simulate_peer_eclipse(
            honest_nodes=100,
            sybil_nodes=sybil_count,
            trials=eclipse_trials,
            sybil_source_count=source_count,
            sybil_diversity=diversity,
        )
        for sybil_count, source_count, diversity in (
            (10_000, 1, "spoofed"),
            (1_000, 2, "single-operator"),
            (1_000, 2, "spoofed"),
        )
    ]
    relay_failure = [
        simulate_relay_failure(
            relay_count=100,
            failure_probability=0.30,
            route_count=route_count,
            required_routes=required_routes,
            trials=trials,
        )
        for route_count, required_routes in ((1, 1), (3, 1), (10, 6))
    ]
    return {
        "model": "ouo-trust-simulator/3",
        "scope": (
            "Capability structural/quorum enforcement and random committee capture only; "
            "not a proof of network-wide Sybil resistance"
        ),
        "peer_eclipse_scope": (
            "Conditional selector model after candidates already hold valid Relay capability; "
            "spoofed diversity demonstrates residual risk if certification/operator diversity fails"
        ),
        "sybil": [asdict(result) for result in sybil],
        "committee_capture": [
            {**asdict(result), "capture_rate": result.capture_rate} for result in capture
        ],
        "peer_eclipse": [
            {
                **asdict(result),
                "guard_capture_rate": result.guard_capture_rate,
                "active_eclipse_rate": result.active_eclipse_rate,
                "mean_malicious_active_fraction": result.mean_malicious_active_fraction,
            }
            for result in eclipse
        ],
        "relay_failure_scope": (
            "Independent Relay availability baseline; no latency, shared failure domain, "
            "queueing, adversarial routing, or privacy claim"
        ),
        "relay_failure": [
            {**asdict(result), "delivery_rate": result.delivery_rate}
            for result in relay_failure
        ],
    }
