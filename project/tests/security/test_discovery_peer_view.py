from datetime import datetime, timedelta, timezone

from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.discovery_peer_view import aggregate_discovery_peer_view
from shared.security.keys import public_key_b64
from shared.security.node_advertisement import (
    issue_node_advertisement,
    node_advertisement_hash,
)
from shared.security.node_advertisement_observation import issue_advertisement_observation
from shared.security.node_identity import (
    issue_operational_certificate,
    node_id_from_root_public_key,
)


NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _authority():
    keys = {f"validator-{index}": SigningKey.generate() for index in range(3)}
    state = CapabilityAuthorityState(
        epoch=5,
        committee=tuple(sorted(keys)),
        threshold=2,
        validators={
            validator_id: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=NOW + timedelta(days=5),
            )
            for validator_id, key in keys.items()
        },
    )
    return state, keys


def _subject():
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=NOW - timedelta(hours=1),
        valid_until=NOW + timedelta(days=2),
    )
    return certificate["node_id"], operational, certificate


def _advertisement(subject, operational, operational_certificate, endpoint="wss://relay.example/ws"):
    return issue_node_advertisement(
        operational_signing_key=operational,
        operational_certificate=operational_certificate,
        endpoints=[endpoint],
        supported_transports=["wss"],
        supported_protocols=["ouo-federation/1"],
        epoch=12,
        issued_at=NOW - timedelta(minutes=1),
        expires_at=NOW + timedelta(hours=1),
    )


def _capability(subject, state, keys, capabilities=("relay",)):
    certificate = build_capability_certificate(
        subject_node_id=subject,
        level=2,
        capabilities=capabilities,
        quotas={"max_connections": 100},
        epoch=state.epoch,
        issued_at=NOW - timedelta(minutes=1),
        valid_until=NOW + timedelta(days=1),
        committee=state.committee,
        threshold=state.threshold,
    )
    for validator_id in state.committee[: state.threshold]:
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return certificate


def _discovery_source():
    root = SigningKey.generate()
    operational = SigningKey.generate()
    source_id = node_id_from_root_public_key(bytes(root.verify_key))
    return source_id, operational, ValidatorCredential(
        public_key=public_key_b64(operational),
        valid_until=NOW + timedelta(days=1),
    )


def _item(advertisement, capability, source_id, source_key):
    return {
        "advertisement": advertisement,
        "capability_certificate": capability,
        "observation": issue_advertisement_observation(
            source_node_id=source_id,
            subject_node_id=advertisement["node_id"],
            advertisement_epoch=advertisement["epoch"],
            advertisement_hash=node_advertisement_hash(advertisement),
            observed_at=NOW,
            expires_at=NOW + timedelta(minutes=5),
            source_signing_key=source_key,
        ),
    }


def _fixture():
    authority, validator_keys = _authority()
    subject, operational, operational_certificate = _subject()
    advertisement = _advertisement(subject, operational, operational_certificate)
    capability = _capability(subject, authority, validator_keys)
    sources = [_discovery_source() for _ in range(3)]
    credentials = {source[0]: source[2] for source in sources}
    return authority, validator_keys, subject, operational, operational_certificate, advertisement, capability, sources, credentials


def test_two_independent_sources_produce_selector_ready_candidate():
    authority, _, subject, _, _, advertisement, capability, sources, credentials = _fixture()
    view = aggregate_discovery_peer_view(
        [_item(advertisement, capability, *source[:2]) for source in sources[:2]],
        now=NOW,
        authority_state=authority,
        trusted_discovery_sources=credentials,
        diversity_groups={subject: "operator-a"},
    )
    assert view.conflicts == ()
    assert view.rejected_count == 0
    assert len(view.candidates) == 1
    assert view.candidates[0] == {
        "node_id": subject,
        "endpoint": "wss://relay.example/ws",
        "capabilities": ["relay"],
        "observed_by": sorted([sources[0][0], sources[1][0]]),
        "diversity_group": "operator-a",
        "validated": True,
        "advertisement_epoch": 12,
        "capability_epoch": 5,
        "level": 2,
    }


def test_one_source_or_unknown_source_cannot_make_candidate():
    authority, _, _, _, _, advertisement, capability, sources, credentials = _fixture()
    one = aggregate_discovery_peer_view(
        [_item(advertisement, capability, *sources[0][:2])],
        now=NOW,
        authority_state=authority,
        trusted_discovery_sources=credentials,
    )
    assert one.candidates == ()
    unknown = aggregate_discovery_peer_view(
        [_item(advertisement, capability, *sources[0][:2])],
        now=NOW,
        authority_state=authority,
        trusted_discovery_sources={},
    )
    assert unknown.candidates == ()
    assert unknown.rejected_count == 1


def test_conflicting_signed_advertisements_for_same_epoch_fail_closed():
    authority, _, subject, operational, operational_certificate, advertisement, capability, sources, credentials = _fixture()
    conflicting = _advertisement(
        subject,
        operational,
        operational_certificate,
        endpoint="wss://other.example/ws",
    )
    view = aggregate_discovery_peer_view(
        [
            _item(advertisement, capability, *sources[0][:2]),
            _item(conflicting, capability, *sources[1][:2]),
        ],
        now=NOW,
        authority_state=authority,
        trusted_discovery_sources=credentials,
    )
    assert view.candidates == ()
    assert view.conflicts == (subject,)


def test_capabilities_are_intersected_across_sources():
    authority, validator_keys, subject, _, _, advertisement, capability, sources, credentials = _fixture()
    extended = _capability(subject, authority, validator_keys, capabilities=("home", "relay"))
    view = aggregate_discovery_peer_view(
        [
            _item(advertisement, capability, *sources[0][:2]),
            _item(advertisement, extended, *sources[1][:2]),
        ],
        now=NOW,
        authority_state=authority,
        trusted_discovery_sources=credentials,
    )
    assert view.candidates[0]["capabilities"] == ["relay"]
