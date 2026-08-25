import base64
import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import HTTPException
from nacl.public import PrivateKey
from nacl.signing import SigningKey

from shared.security.capability_certificate import (
    ValidatorCredential,
    add_validator_signature,
    build_capability_certificate,
    capability_certificate_hash,
)
from shared.security.capability_enrollment import CapabilityAuthorityState
from shared.security.keys import public_key_b64
from shared.security.node_advertisement import (
    issue_node_advertisement,
    node_advertisement_hash,
)
from shared.security.node_advertisement_observation import issue_advertisement_observation
from shared.security.node_identity import issue_operational_certificate
from shared.security.transport_certificate import issue_transport_certificate


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"
_TRANSPORT_CERTIFICATES = {}


@contextmanager
def _modules():
    previous = {
        name: module
        for name, module in sys.modules.items()
        if name == "app" or name.startswith("app.")
    }
    for name in previous:
        del sys.modules[name]
    sys.path.insert(0, str(DISCOVERY_ROOT))
    try:
        db = importlib.import_module("app.db")
        gossip = importlib.import_module("app.node_advertisement_gossip")
        yield db, gossip
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


def _authority(now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(3)}
    state = CapabilityAuthorityState(
        epoch=4,
        committee=tuple(sorted(keys)),
        threshold=2,
        validators={
            name: ValidatorCredential(
                public_key=public_key_b64(key),
                valid_until=now + timedelta(days=2),
            )
            for name, key in keys.items()
        },
    )
    return keys, state


def _identity(now):
    root = SigningKey.generate()
    operational = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=root,
        operational_verify_key=operational.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    _TRANSPORT_CERTIFICATES[certificate["node_id"]] = issue_transport_certificate(
        root_signing_key=root,
        transport_private_key=PrivateKey.generate(),
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return operational, certificate


def _capability(
    subject,
    capabilities,
    level,
    keys,
    state,
    now,
    *,
    epoch=None,
    previous_hash=None,
    max_connections=100,
):
    certificate = build_capability_certificate(
        subject_node_id=subject,
        level=level,
        capabilities=capabilities,
        quotas={"max_connections": max_connections},
        epoch=state.epoch if epoch is None else epoch,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(hours=12),
        committee=state.committee,
        threshold=state.threshold,
        previous_hash=previous_hash,
    )
    for validator_id in state.committee[: state.threshold]:
        certificate = add_validator_signature(
            certificate,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return certificate


def _advertisement(operational, certificate, now, endpoint="wss://relay.example/ws"):
    return issue_node_advertisement(
        operational_signing_key=operational,
        operational_certificate=certificate,
        endpoints=[endpoint],
        supported_transports=["wss"],
        supported_protocols=["ouo-federation/1"],
        epoch=7,
        issued_at=now - timedelta(seconds=5),
        expires_at=now + timedelta(hours=1),
    )


def _insert_node(db, alias, operational_certificate, capability, advertisement, now):
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, software_version, last_heartbeat,
                   trust_status, registered_at, signing_public_key, identity_node_id,
                   operational_certificate, node_identity_status,
                   node_advertisement, node_advertisement_status, node_advertisement_epoch,
                   capability_certificate, capability_certificate_status,
                   certified_capabilities, certified_level, capability_epoch,
                   transport_certificate, transport_certificate_status
               ) VALUES (?, ?, ?, 'test', ?, 'trusted', ?, ?, ?, ?, 'valid', ?, 'valid', ?, ?, 'valid', ?, ?, ?, ?, 'valid')""",
            (
                alias,
                advertisement["endpoints"][0] if advertisement else "https://discovery.example",
                json.dumps(capability["capabilities"]),
                now.isoformat(),
                now.isoformat(),
                operational_certificate["operational_public_key"],
                operational_certificate["node_id"],
                json.dumps(operational_certificate),
                json.dumps(advertisement) if advertisement else None,
                advertisement["epoch"] if advertisement else None,
                json.dumps(capability),
                json.dumps(capability["capabilities"]),
                capability["level"],
                capability["epoch"],
                json.dumps(_TRANSPORT_CERTIFICATES[operational_certificate["node_id"]]),
            ),
        )
        conn.commit()


def _gossip_item(source_key, source_certificate, advertisement, capability, now):
    return {
        "advertisement": advertisement,
        "capability_certificate": capability,
        "transport_certificate": _TRANSPORT_CERTIFICATES[advertisement["node_id"]],
        "observation": issue_advertisement_observation(
            source_node_id=source_certificate["node_id"],
            subject_node_id=advertisement["node_id"],
            advertisement_epoch=advertisement["epoch"],
            advertisement_hash=node_advertisement_hash(advertisement),
            observed_at=now,
            expires_at=now + timedelta(minutes=5),
            source_signing_key=source_key,
        ),
    }


def test_same_observation_is_validated_and_persisted_on_three_discovery_dbs(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        source_key, source_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        source_capability = _capability(
            source_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        subject_capability = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        advertisement = _advertisement(subject_key, subject_certificate, now)
        item = _gossip_item(
            source_key, source_certificate, advertisement, subject_capability, now
        )
        gossip._authority_state = lambda: authority

        accepted = []
        for index in range(3):
            db.DB_PATH = str(tmp_path / f"d{index + 1}.db")
            db.init_db()
            _insert_node(
                db, "discovery-source", source_certificate, source_capability, None, now
            )
            result = gossip.ingest_advertisement_gossip(item, now=now)
            accepted.append(result["accepted"])
            stored = gossip.list_stored_observations(now=now)
            assert stored == [item]
        assert accepted == [True, True, True]


def test_source_equivocation_for_same_subject_epoch_is_rejected(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        source_key, source_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        source_capability = _capability(
            source_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        subject_capability = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        first = _advertisement(subject_key, subject_certificate, now)
        second = _advertisement(
            subject_key, subject_certificate, now, endpoint="wss://other.example/ws"
        )
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, "source", source_certificate, source_capability, None, now)
        gossip._authority_state = lambda: authority
        gossip.ingest_advertisement_gossip(
            _gossip_item(source_key, source_certificate, first, subject_capability, now),
            now=now,
        )
        with pytest.raises(gossip.AdvertisementObservationConflict):
            gossip.ingest_advertisement_gossip(
                _gossip_item(source_key, source_certificate, second, subject_capability, now),
                now=now,
            )


def test_two_discovery_sources_form_a_selector_ready_peer_view(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        source_a_key, source_a_certificate = _identity(now)
        source_b_key, source_b_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        source_a_capability = _capability(
            source_a_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        source_b_capability = _capability(
            source_b_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        subject_capability = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        advertisement = _advertisement(subject_key, subject_certificate, now)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, "source-a", source_a_certificate, source_a_capability, None, now)
        _insert_node(db, "source-b", source_b_certificate, source_b_capability, None, now)
        gossip._authority_state = lambda: authority
        for source_key, source_certificate in (
            (source_a_key, source_a_certificate),
            (source_b_key, source_b_certificate),
        ):
            gossip.ingest_advertisement_gossip(
                _gossip_item(
                    source_key,
                    source_certificate,
                    advertisement,
                    subject_capability,
                    now,
                ),
                now=now,
            )

        view = gossip.build_peer_view(capability="relay", now=now)
        assert view["trusted_source_count"] == 2
        assert view["conflicts"] == []
        assert len(view["candidates"]) == 1
        assert view["candidates"][0]["node_id"] == subject_certificate["node_id"]
        assert view["candidates"][0]["observed_by"] == sorted(
            [source_a_certificate["node_id"], source_b_certificate["node_id"]]
        )


def test_peer_view_waits_for_two_sources_to_converge_on_new_capability_head(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        source_a_key, source_a_certificate = _identity(now)
        source_b_key, source_b_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        source_a_capability = _capability(
            source_a_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        source_b_capability = _capability(
            source_b_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        first = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        advertisement = _advertisement(subject_key, subject_certificate, now)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, "source-a", source_a_certificate, source_a_capability, None, now)
        _insert_node(db, "source-b", source_b_certificate, source_b_capability, None, now)
        gossip._authority_state = lambda: authority
        sources = (
            (source_a_key, source_a_certificate),
            (source_b_key, source_b_certificate),
        )
        for source_key, source_certificate in sources:
            gossip.ingest_advertisement_gossip(
                _gossip_item(source_key, source_certificate, advertisement, first, now),
                now=now,
            )
        assert len(gossip.build_peer_view(capability="relay", now=now)["candidates"]) == 1

        authority = CapabilityAuthorityState(
            epoch=5,
            committee=authority.committee,
            threshold=authority.threshold,
            validators=authority.validators,
        )
        for alias, certificate, previous in (
            ("source-a", source_a_certificate, source_a_capability),
            ("source-b", source_b_certificate, source_b_capability),
        ):
            renewed = _capability(
                certificate["node_id"],
                ["discovery"],
                4,
                authority_keys,
                authority,
                now,
                previous_hash=capability_certificate_hash(previous),
            )
            with db.get_conn() as conn:
                conn.execute(
                    """UPDATE node_capabilities SET capability_certificate = ?,
                              capability_epoch = ? WHERE node_id = ?""",
                    (json.dumps(renewed), renewed["epoch"], alias),
                )
                conn.commit()
        second = _capability(
            subject_certificate["node_id"],
            ["relay"],
            2,
            authority_keys,
            authority,
            now,
            previous_hash=capability_certificate_hash(first),
        )
        gossip.ingest_advertisement_gossip(
            _gossip_item(source_a_key, source_a_certificate, advertisement, second, now),
            now=now,
        )
        assert gossip.build_peer_view(capability="relay", now=now)["candidates"] == []

        gossip.ingest_advertisement_gossip(
            _gossip_item(source_b_key, source_b_certificate, advertisement, second, now),
            now=now,
        )
        converged = gossip.build_peer_view(capability="relay", now=now)
        assert len(converged["candidates"]) == 1
        assert converged["candidates"][0]["capability_epoch"] == 5

        with pytest.raises(HTTPException) as replay:
            gossip.ingest_advertisement_gossip(
                _gossip_item(source_a_key, source_a_certificate, advertisement, first, now),
                now=now,
            )
        assert replay.value.status_code in {403, 409}
        assert any(
            marker in str(replay.value.detail)
            for marker in ("rollback", "authority_epoch mismatch")
        )


def test_conflicting_quorum_capability_epoch_is_preserved_as_evidence(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        source_key, source_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        source_capability = _capability(
            source_certificate["node_id"], ["discovery"], 4, authority_keys, authority, now
        )
        first = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        conflicting = _capability(
            subject_certificate["node_id"],
            ["relay"],
            2,
            authority_keys,
            authority,
            now,
            max_connections=101,
        )
        advertisement = _advertisement(subject_key, subject_certificate, now)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, "source", source_certificate, source_capability, None, now)
        gossip._authority_state = lambda: authority
        gossip.ingest_advertisement_gossip(
            _gossip_item(source_key, source_certificate, advertisement, first, now),
            now=now,
        )
        with pytest.raises(gossip.CapabilityCertificateConflict):
            gossip.ingest_advertisement_gossip(
                _gossip_item(
                    source_key,
                    source_certificate,
                    advertisement,
                    conflicting,
                    now,
                ),
                now=now,
            )
        with db.get_conn() as conn:
            count = conn.execute(
                "SELECT COUNT(*) FROM capability_certificate_conflicts"
            ).fetchone()[0]
        assert count == 1


def test_local_gossip_api_emits_fresh_operationally_signed_observation(tmp_path):
    with _modules() as (db, gossip):
        now = datetime.now(timezone.utc)
        authority_keys, authority = _authority(now)
        discovery_key, discovery_certificate = _identity(now)
        subject_key, subject_certificate = _identity(now)
        subject_capability = _capability(
            subject_certificate["node_id"], ["relay"], 2, authority_keys, authority, now
        )
        advertisement = _advertisement(subject_key, subject_certificate, now)
        db.DB_PATH = str(tmp_path / "discovery.db")
        db.init_db()
        _insert_node(db, "relay", subject_certificate, subject_capability, advertisement, now)
        key_path = tmp_path / "discovery-operational.key"
        key_path.write_text(base64.urlsafe_b64encode(bytes(discovery_key)).decode())
        gossip.DISCOVERY_NODE_OPERATIONAL_KEY_PATH = str(key_path)
        gossip.discovery_node_identity = lambda: {
            "operational_certificate": discovery_certificate
        }
        gossip._authority_state = lambda: authority

        items = gossip.build_local_gossip_items(now=now)
        assert len(items) == 1
        assert items[0]["advertisement"] == advertisement
        assert items[0]["observation"]["source_node_id"] == discovery_certificate["node_id"]
