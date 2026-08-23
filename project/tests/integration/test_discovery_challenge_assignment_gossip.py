import hashlib
import importlib
import json
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey

from shared.security.capability_enrollment import parse_capability_authority_state
from shared.security.challenge_assignment import (
    add_assignment_signature,
    build_challenge_assignment,
    challenge_assignment_ack_hash,
    challenge_assignment_hash,
    issue_assignment_ack,
)
from shared.security.keys import public_key_b64
from shared.security.node_identity import issue_operational_certificate
from shared.security.observer_auth import issue_observer_request_proof
from shared.security.operational_credential_revocation import (
    operational_certificate_hash,
)
from shared.security.trust_evidence import issue_reliability_observation


PROJECT_ROOT = Path(__file__).parents[2]
DISCOVERY_ROOT = PROJECT_ROOT / "services" / "discovery-node"


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
        store = importlib.import_module("app.challenge_assignment_store")
        gossip = importlib.import_module("app.challenge_assignment_gossip")
        ack_gossip = importlib.import_module("app.challenge_assignment_ack_gossip")
        observation_store = importlib.import_module("app.trust_observation_store")
        observation_gossip = importlib.import_module("app.trust_observation_gossip")
        yield db, store, gossip, ack_gossip, observation_store, observation_gossip
    finally:
        sys.path.remove(str(DISCOVERY_ROOT))
        for name in [name for name in sys.modules if name == "app" or name.startswith("app.")]:
            del sys.modules[name]
        sys.modules.update(previous)


class _Guard:
    def __init__(self):
        self.frozen_reason = None

    def force_freeze(self, reason):
        self.frozen_reason = reason


def _authority(tmp_path, now):
    keys = {f"validator-{index}": SigningKey.generate() for index in range(7)}
    raw = {
        "epoch": 12,
        "committee": sorted(keys),
        "threshold": 5,
        "validators": {
            validator_id: {
                "public_key": public_key_b64(key),
                "valid_until": (now + timedelta(days=2)).isoformat(),
                "revoked": False,
            }
            for validator_id, key in keys.items()
        },
    }
    path = tmp_path / "authority.json"
    path.write_text(json.dumps(raw), encoding="utf-8")
    return keys, parse_capability_authority_state(raw), path


def _identity(now):
    key = SigningKey.generate()
    certificate = issue_operational_certificate(
        root_signing_key=SigningKey.generate(),
        operational_verify_key=key.verify_key,
        issued_at=now - timedelta(minutes=1),
        valid_until=now + timedelta(days=1),
    )
    return key, certificate


def _insert_node(db, alias, certificate):
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with db.get_conn() as conn:
        conn.execute(
            """INSERT INTO node_capabilities (
                   node_id, node_url, capabilities, software_version,
                   last_heartbeat, trust_status, registered_at,
                   signing_public_key, identity_node_id,
                   operational_certificate, node_identity_status
               ) VALUES (?, ?, '[\"home\"]', 'test', ?, 'trusted', ?, ?, ?, ?, 'valid')""",
            (
                alias,
                f"https://{alias}.example",
                now,
                now,
                certificate["operational_public_key"],
                certificate["node_id"],
                json.dumps(certificate),
            ),
        )
        conn.commit()


def _assignment(keys, subject, observer, now):
    assignment = build_challenge_assignment(
        subject_node_id=subject,
        observer_node_ids=[observer],
        challenge_type="relay_delivery",
        epoch=12,
        randomness_commitment=hashlib.sha256(b"quorum-randomness").hexdigest(),
        not_before=now - timedelta(minutes=1),
        expires_at=now + timedelta(minutes=30),
        committee=sorted(keys),
        threshold=5,
    )
    for validator_id in sorted(keys)[:5]:
        assignment = add_assignment_signature(
            assignment,
            validator_id=validator_id,
            validator_signing_key=keys[validator_id],
        )
    return assignment


def _configure(gossip, authority_path, guard):
    gossip.TRUST_AUTHORITY_STATE_PATH = str(authority_path)
    gossip.require_governance_available = lambda: None
    gossip.get_network_view_guard = lambda: guard


def test_assignment_converges_before_participants_register_on_replica(tmp_path):
    with _modules() as (
        db,
        store,
        gossip,
        ack_gossip,
        observation_store,
        observation_gossip,
    ):
        now = datetime.now(timezone.utc)
        keys, authority, path = _authority(tmp_path, now)
        observer_key, observer = _identity(now)
        _, subject = _identity(now)
        assignment = _assignment(keys, subject["node_id"], observer["node_id"], now)

        db.DB_PATH = str(tmp_path / "d1.db")
        db.init_db()
        _insert_node(db, "observer", observer)
        _insert_node(db, "subject", subject)
        store.publish_assignment(assignment, authority=authority, now=now)
        page = gossip.build_assignment_gossip(after_sequence=0, limit=100)
        assert page["head_sequence"] == 1

        db.DB_PATH = str(tmp_path / "d2.db")
        db.init_db()
        store.TRUST_LEDGER_DB_PATH = str(tmp_path / "d2-trust-ledger.db")
        _configure(gossip, path, _Guard())
        result = gossip.ingest_assignment_gossip(page["assignments"][0])
        assert result["accepted"] is True

        proof = issue_observer_request_proof(
            observer_signing_key=observer_key,
            operational_certificate=observer,
            action="challenge_assignment_pull",
            payload={"limit": 20},
            issued_at=now,
            expires_at=now + timedelta(minutes=2),
        )
        portable = store.pull_assignments_with_proof(proof, limit=20, now=now)
        assert len(portable) == 1
        with pytest.raises(HTTPException) as replay:
            store.pull_assignments_with_proof(proof, limit=20, now=now)
        assert replay.value.status_code == 409

        ack = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=observer["node_id"],
            decision="accepted",
            acknowledged_at=now,
            observer_signing_key=observer_key,
        )
        ack_id, state, accepted = store.acknowledge_assignment(
            ack,
            authorization=None,
            observer_certificate=observer,
            now=now,
        )
        assert (ack_id, state, accepted) == (
            assignment["assignment_id"],
            "accepted",
            True,
        )
        observation = issue_reliability_observation(
            observer_node_id=observer["node_id"],
            subject_node_id=subject["node_id"],
            epoch=assignment["epoch"],
            challenge_type=assignment["challenge_type"],
            challenge_commitment=hashlib.sha256(b"assigned-probe").hexdigest(),
            result="success",
            latency_bucket="20_50ms",
            observed_at=now,
            expires_at=now + timedelta(hours=1),
            observer_signing_key=observer_key,
        )
        observation_id, observation_accepted = observation_store.publish_observation(
            observation,
            authorization=None,
            assignment_id=assignment["assignment_id"],
            observer_certificate=observer,
            now=now,
        )
        assert observation_id == observation["observation_id"]
        assert observation_accepted is True

        _insert_node(db, "observer", observer)
        _insert_node(db, "subject", subject)
        pulled = store.pull_assignments(
            observer["node_id"], authorization=None, now=now, limit=20
        )
        assert len(pulled) == 1
        assert pulled[0]["assignment"] == assignment
        assert pulled[0]["state"] == "completed"

        ack_page = ack_gossip.build_ack_gossip(after_sequence=0, limit=100)
        assert ack_page["head_sequence"] == 1
        assert len(ack_page["acknowledgements"]) == 1
        observation_page = observation_gossip.build_observation_gossip(
            after_sequence=0, limit=100
        )
        assert observation_page["head_sequence"] == 1
        assert len(observation_page["observations"]) == 1

        db.DB_PATH = str(tmp_path / "d3.db")
        db.init_db()
        revocation_store = importlib.import_module(
            "app.operational_credential_revocation_store"
        )
        revocation_store.OPERATIONAL_CREDENTIAL_REVOCATION_MODE = "enforce"
        effective_at = (now + timedelta(seconds=1)).isoformat().replace(
            "+00:00", "Z"
        )
        with db.get_conn() as conn:
            conn.execute(
                """INSERT INTO operational_credential_revocations (
                       node_id, revocation_epoch, revocation_hash, previous_hash,
                       credential_epoch, certificate_serial, certificate_hash,
                       operational_public_key, authority_epoch, effective_at,
                       revocation_json, stored_at
                   ) VALUES (?, 0, ?, ?, 0, ?, ?, ?, 12, ?, '{}', ?)""",
                (
                    observer["node_id"],
                    hashlib.sha256(b"revocation").hexdigest(),
                    hashlib.sha256(b"genesis").hexdigest(),
                    observer["serial"],
                    operational_certificate_hash(observer),
                    observer["operational_public_key"],
                    effective_at,
                    effective_at,
                ),
            )
            conn.commit()
        store.TRUST_LEDGER_DB_PATH = str(tmp_path / "d3-trust-ledger.db")
        _configure(gossip, path, _Guard())
        gossip.ingest_assignment_gossip(page["assignments"][0])
        replicated_ack = ack_gossip.ingest_ack_gossip(
            ack_page["acknowledgements"][0]
        )
        assert replicated_ack["accepted"] is True
        replicated_observation = observation_gossip.ingest_observation_gossip(
            observation_page["observations"][0]
        )
        assert replicated_observation["accepted"] is True
        # The same certificate is denied for live work after effective_at,
        # while the two pre-revocation signed events remain valid history.
        with pytest.raises(HTTPException, match="revoked"):
            revocation_store.require_operational_credential_not_revoked(
                observer, at_time=now + timedelta(seconds=2)
            )
        _insert_node(db, "observer-d3", observer)
        replicated = store.pull_assignments(
            observer["node_id"], authorization=None, now=now, limit=20
        )
        assert replicated[0]["state"] == "completed"
        assert replicated[0]["ack"] == ack
        assert replicated[0]["completed_observation_id"] == observation["observation_id"]


def test_conflicting_quorum_assignment_gossip_freezes(tmp_path):
    with _modules() as (db, store, gossip, _ack_gossip, _obs_store, _obs_gossip):
        now = datetime.now(timezone.utc)
        keys, authority, path = _authority(tmp_path, now)
        _, observer = _identity(now)
        _, subject = _identity(now)
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        first = _assignment(keys, subject["node_id"], observer["node_id"], now)
        store.publish_assignment(
            first,
            authority=authority,
            now=now,
            require_registered_participants=False,
        )
        conflicting = _assignment(keys, subject["node_id"], observer["node_id"], now)
        guard = _Guard()
        _configure(gossip, path, guard)
        item = {
            "sequence": 2,
            "assignment_hash": challenge_assignment_hash(conflicting),
            "assignment": conflicting,
        }
        with pytest.raises(HTTPException) as error:
            gossip.ingest_assignment_gossip(item)
        assert error.value.status_code == 409
        assert guard.frozen_reason == "conflicting quorum ChallengeAssignments detected"


@pytest.mark.asyncio
async def test_background_pull_revalidates_assignment(tmp_path):
    with _modules() as (db, store, gossip, _ack_gossip, _obs_store, _obs_gossip):
        now = datetime.now(timezone.utc)
        keys, _authority_state, path = _authority(tmp_path, now)
        _, observer = _identity(now)
        _, subject = _identity(now)
        assignment = _assignment(keys, subject["node_id"], observer["node_id"], now)
        item = {
            "sequence": 1,
            "assignment_hash": challenge_assignment_hash(assignment),
            "assignment": assignment,
        }
        db.DB_PATH = str(tmp_path / "receiver.db")
        db.init_db()
        _configure(gossip, path, _Guard())
        gossip._peer_cursors.clear()

        def handler(request):
            assert request.url.host == "d1.test"
            return httpx.Response(
                200,
                json={"assignments": [item], "head_sequence": 1},
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await gossip.poll_assignment_peers_once(
                peers=("https://d1.test",), client=client
            )
        assert result == {"fetched": 1, "accepted": 1, "failed_peers": 0}


@pytest.mark.asyncio
async def test_background_pull_revalidates_signed_ack(tmp_path):
    with _modules() as (
        db,
        store,
        _gossip,
        ack_gossip,
        _obs_store,
        _obs_gossip,
    ):
        now = datetime.now(timezone.utc)
        keys, authority, _path = _authority(tmp_path, now)
        observer_key, observer = _identity(now)
        _, subject = _identity(now)
        assignment = _assignment(keys, subject["node_id"], observer["node_id"], now)
        db.DB_PATH = str(tmp_path / "receiver-ack.db")
        db.init_db()
        store.TRUST_LEDGER_DB_PATH = str(tmp_path / "receiver-ack-ledger.db")
        store.publish_assignment(
            assignment,
            authority=authority,
            now=now,
            require_registered_participants=False,
        )
        ack = issue_assignment_ack(
            assignment_id=assignment["assignment_id"],
            observer_node_id=observer["node_id"],
            decision="accepted",
            acknowledged_at=now,
            observer_signing_key=observer_key,
        )
        item = {
            "sequence": 1,
            "ack_hash": challenge_assignment_ack_hash(ack),
            "ack": ack,
            "operational_certificate": observer,
        }
        ack_gossip._peer_cursors.clear()

        def handler(request):
            assert request.url.path == ack_gossip.GOSSIP_PATH
            return httpx.Response(
                200,
                json={"acknowledgements": [item], "head_sequence": 1},
            )

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await ack_gossip.poll_ack_peers_once(
                peers=("https://d1.test",), client=client
            )
        assert result == {"fetched": 1, "accepted": 1, "failed_peers": 0}
        with db.get_conn() as conn:
            row = conn.execute(
                """SELECT state, ack_json FROM challenge_assignment_observers
                   WHERE assignment_id = ? AND observer_node_id = ?""",
                (assignment["assignment_id"], observer["node_id"]),
            ).fetchone()
        assert row["state"] == "accepted"
        assert json.loads(row["ack_json"]) == ack
