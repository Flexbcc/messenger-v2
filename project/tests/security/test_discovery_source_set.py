from datetime import datetime, timedelta, timezone

import pytest
from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.discovery_source_set import parse_discovery_source_credentials
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _authority():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(3)}
    state = CapabilityAuthorityState(
        epoch=9,
        committee=tuple(sorted(keys)),
        threshold=2,
        validators={
            name: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=NOW + timedelta(days=2),
            )
            for name, key in keys.items()
        },
    )
    return keys, state


def _source(keys, state, capabilities=("discovery",)):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    identity = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=1),
    )
    capability = build_capability_certificate(
        subject_node_id=identity["node_id"],
        level=4,
        capabilities=capabilities,
        quotas={"max_connections": 100},
        epoch=state.epoch,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(hours=12),
        committee=state.committee,
        threshold=state.threshold,
    )
    for validator_id in state.committee[: state.threshold]:
        capability = add_validator_signature(
            capability,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return {
        "operational_certificate": identity,
        "capability_certificate": capability,
    }


def test_source_set_requires_root_identity_and_quorum_discovery_capability():
    keys, authority = _authority()
    sources = [_source(keys, authority) for _ in range(3)]
    result = parse_discovery_source_credentials(
        {
            "protocol_version": "ouo-discovery-source-set/1",
            "authority_epoch": authority.epoch,
            "sources": sources,
        },
        authority_state=authority,
        now=NOW,
    )
    assert set(result) == {
        source["operational_certificate"]["node_id"] for source in sources
    }


def test_source_set_rejects_wrong_epoch_duplicate_or_non_discovery_source():
    keys, authority = _authority()
    source = _source(keys, authority)
    with pytest.raises(ValueError, match="authority epoch mismatch"):
        parse_discovery_source_credentials(
            {
                "protocol_version": "ouo-discovery-source-set/1",
                "authority_epoch": authority.epoch - 1,
                "sources": [source],
            },
            authority_state=authority,
            now=NOW,
        )
    with pytest.raises(ValueError, match="duplicate"):
        parse_discovery_source_credentials(
            {
                "protocol_version": "ouo-discovery-source-set/1",
                "authority_epoch": authority.epoch,
                "sources": [source, source],
            },
            authority_state=authority,
            now=NOW,
        )
    relay = _source(keys, authority, capabilities=("relay",))
    with pytest.raises(ValueError, match="lacks discovery capability"):
        parse_discovery_source_credentials(
            {
                "protocol_version": "ouo-discovery-source-set/1",
                "authority_epoch": authority.epoch,
                "sources": [relay],
            },
            authority_state=authority,
            now=NOW,
        )
