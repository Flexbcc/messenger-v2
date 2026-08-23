"""Fail-closed aggregation of independently signed Discovery peer observations."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping, Sequence
from urllib.parse import urlsplit

from shared.security.capability_certificate import (
    ValidatorCredential,
    validate_capability_certificate,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.node_advertisement import (
    node_advertisement_hash,
    validate_node_advertisement,
)
from shared.security.node_advertisement_observation import (
    validate_advertisement_observation,
)


MAX_ITEMS = 1000


@dataclass(frozen=True)
class DiscoveryPeerView:
    candidates: tuple[dict[str, Any], ...]
    conflicts: tuple[str, ...]
    rejected_count: int


def _secure_endpoint(advertisement: Mapping[str, Any]) -> str | None:
    transports = set(advertisement["supported_transports"])
    endpoints = advertisement["endpoints"]
    for preferred_scheme in ("wss", "https"):
        if preferred_scheme not in transports:
            continue
        for endpoint in endpoints:
            if urlsplit(endpoint).scheme == preferred_scheme:
                return endpoint
    return None


def aggregate_discovery_peer_view(
    items: Sequence[Mapping[str, Any]],
    *,
    now: datetime,
    authority_state: CapabilityAuthorityState,
    trusted_discovery_sources: Mapping[str, ValidatorCredential],
    diversity_groups: Mapping[str, str] | None = None,
    minimum_sources: int = 2,
    minimum_advertisement_epoch: int = 0,
) -> DiscoveryPeerView:
    """Validate observations and emit selector-ready candidates.

    ``trusted_discovery_sources`` is deliberately external input: source identity
    authentication alone is not a Discovery capability. Callers must derive this
    map from the current, quorum-certified Discovery set.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("validation time must be timezone-aware")
    if not 2 <= minimum_sources <= 16:
        raise ValueError("minimum_sources must be between 2 and 16")
    if len(items) > MAX_ITEMS:
        raise ValueError("Discovery peer view exceeds item limit")

    rejected = 0
    valid: list[tuple[Mapping[str, Any], Mapping[str, Any], Mapping[str, Any], str]] = []
    for item in items:
        if not isinstance(item, Mapping) or set(item) != {
            "advertisement",
            "capability_certificate",
            "observation",
        }:
            rejected += 1
            continue
        advertisement = item["advertisement"]
        certificate = item["capability_certificate"]
        observation = item["observation"]
        if not isinstance(advertisement, Mapping) or not isinstance(certificate, Mapping):
            rejected += 1
            continue
        ad_validation = validate_node_advertisement(
            advertisement,
            now=now,
            minimum_epoch=minimum_advertisement_epoch,
        )
        if not ad_validation.valid:
            rejected += 1
            continue
        source_node_id = observation.get("source_node_id") if isinstance(observation, Mapping) else None
        source_credential = trusted_discovery_sources.get(source_node_id)
        if source_credential is None:
            rejected += 1
            continue
        digest = node_advertisement_hash(advertisement)
        observation_validation = validate_advertisement_observation(
            observation,
            now=now,
            expected_subject_node_id=advertisement["node_id"],
            expected_advertisement_epoch=advertisement["epoch"],
            expected_advertisement_hash=digest,
            source_credential=source_credential,
        )
        if not observation_validation.valid:
            rejected += 1
            continue
        capability_validation = validate_capability_certificate(
            certificate,
            now=now,
            expected_committee=authority_state.committee,
            expected_threshold=authority_state.threshold,
            validator_credentials=authority_state.validators,
            minimum_epoch=0,
            expected_authority_epoch=authority_state.epoch,
            expected_subject_node_id=advertisement["node_id"],
        )
        if not capability_validation.valid:
            rejected += 1
            continue
        valid.append((advertisement, certificate, observation, digest))

    conflicts: set[str] = set()
    source_claims: dict[tuple[str, str, int], str] = {}
    subject_claims: dict[tuple[str, int], set[str]] = {}
    for advertisement, _certificate, observation, digest in valid:
        subject = advertisement["node_id"]
        epoch = advertisement["epoch"]
        source_key = (observation["source_node_id"], subject, epoch)
        prior = source_claims.get(source_key)
        if prior is not None and prior != digest:
            conflicts.add(subject)
        source_claims[source_key] = digest
        subject_claims.setdefault((subject, epoch), set()).add(digest)
    for (subject, _epoch), digests in subject_claims.items():
        if len(digests) > 1:
            conflicts.add(subject)

    by_subject: dict[str, list[tuple[Mapping[str, Any], Mapping[str, Any], Mapping[str, Any], str]]] = {}
    for entry in valid:
        by_subject.setdefault(entry[0]["node_id"], []).append(entry)

    candidates: list[dict[str, Any]] = []
    groups = diversity_groups or {}
    for subject in sorted(by_subject):
        if subject in conflicts:
            continue
        entries = by_subject[subject]
        highest_epoch = max(entry[0]["epoch"] for entry in entries)
        current = [entry for entry in entries if entry[0]["epoch"] == highest_epoch]
        digests = {entry[3] for entry in current}
        if len(digests) != 1:
            conflicts.add(subject)
            continue
        sources = sorted({entry[2]["source_node_id"] for entry in current})
        if len(sources) < minimum_sources:
            continue
        endpoint = _secure_endpoint(current[0][0])
        if endpoint is None:
            rejected += len(current)
            continue
        capability_sets = [set(entry[1]["capabilities"]) for entry in current]
        capabilities = sorted(set.intersection(*capability_sets))
        if not capabilities:
            continue
        quota_keys = set.intersection(
            *(set(entry[1].get("quotas", {})) for entry in current)
        )
        quotas = {
            key: min(entry[1]["quotas"][key] for entry in current)
            for key in sorted(quota_keys)
            if all(
                isinstance(entry[1].get("quotas", {}).get(key), int)
                and not isinstance(entry[1]["quotas"][key], bool)
                and entry[1]["quotas"][key] >= 0
                for entry in current
            )
        }
        candidate = {
            "node_id": subject,
            "endpoint": endpoint,
            "capabilities": capabilities,
            "certified_quotas": quotas,
            "observed_by": sources,
            "diversity_group": groups.get(subject, "unknown"),
            "validated": True,
            "advertisement_epoch": highest_epoch,
            "advertisement_expires_at": current[0][0]["expires_at"],
            "observation_valid_until": min(
                entry[2]["expires_at"] for entry in current
            ),
            "operational_certificate": current[0][0]["operational_certificate"],
            "operational_valid_until": current[0][0]["operational_certificate"]["valid_until"],
            "capability_epoch": min(entry[1]["epoch"] for entry in current),
            "capability_valid_until": current[0][1]["valid_until"],
            "level": min(entry[1]["level"] for entry in current),
        }
        candidates.append(candidate)
    return DiscoveryPeerView(tuple(candidates), tuple(sorted(conflicts)), rejected)
